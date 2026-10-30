import { DurableObject } from 'cloudflare:workers'
import { compareVersions } from '../deb/version'
import { type Env, type PackageMeta, type PackageRecord, repoConfig } from '../env'
import { migrate } from './schema'
import { SNAPSHOT_KEEP, buildSnapshot, deleteSnapshots, writeDepictions, writeSnapshot } from './snapshot'

// 全局只有一个实例（名为 "main"），所有写操作在这里串行执行，避免并发发布互相覆盖索引

export type Result<T> = { ok: true; value: T } | { ok: false; status: 404 | 409; detail: string }

export interface PublishResult {
  gen: number
  created: boolean
  record: PackageRecord
}

export interface SnapshotInfo {
  gen: number
  createdAt: number
  reason: string
  entries: number
  packagesSha256: string
}

type PackageRow = {
  package: string
  version: string
  arch: string
  filename: string
  size: number
  md5: string
  sha1: string
  sha256: string
  control: string
  changelog: string | null
  yanked: number
  published_at: number
  actor: string
}

export class RepoIndex extends DurableObject<Env> {
  private sql: SqlStorage

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    ctx.blockConcurrencyWhile(async () => migrate(this.sql))
  }

  // 发布一个已写入 R2 的 deb；同一文件重复发布视为幂等操作
  async publish(record: PackageRecord, options: { force?: boolean } = {}): Promise<Result<PublishResult>> {
    const existing = this.findRecord(record.package, record.version, record.arch)
    if (existing && !existing.yanked && existing.sha256 === record.sha256) {
      return { ok: true, value: { gen: this.currentGen(), created: false, record: existing } }
    }
    if (existing && existing.sha256 !== record.sha256 && !options.force) {
      return { ok: false, status: 409, detail: `${label(record)} 已存在且内容不同` }
    }

    this.sql.exec(
      `INSERT OR REPLACE INTO packages
       (package, version, arch, filename, size, md5, sha1, sha256, control, changelog, yanked, published_at, actor)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
      record.package,
      record.version,
      record.arch,
      record.filename,
      record.size,
      record.md5,
      record.sha1,
      record.sha256,
      JSON.stringify(record.control),
      // 内容相同的重新上架保留原 changelog
      record.changelog ?? existing?.changelog ?? null,
      record.publishedAt,
      record.actor,
    )
    this.audit(record.actor, existing ? 'republish' : 'publish', label(record))
    const gen = await this.rebuild(`publish ${label(record)}`)
    return { ok: true, value: { gen, created: true, record: this.findRecord(record.package, record.version, record.arch)! } }
  }

  // 下架：从索引中移除；purge 时同时删除记录和 R2 文件
  async yank(
    pkg: string,
    version: string,
    options: { arch?: string; purge?: boolean; actor: string },
  ): Promise<Result<{ gen: number; removed: string[] }>> {
    const rows = this.records({ package: pkg, version, arch: options.arch, includeYanked: true })
    if (rows.length === 0) return { ok: false, status: 404, detail: `找不到 ${pkg} ${version}` }

    for (const r of rows) {
      if (options.purge) {
        this.sql.exec('DELETE FROM packages WHERE package = ? AND version = ? AND arch = ?', r.package, r.version, r.arch)
      } else {
        this.sql.exec('UPDATE packages SET yanked = 1 WHERE package = ? AND version = ? AND arch = ?', r.package, r.version, r.arch)
      }
      this.audit(options.actor, options.purge ? 'purge' : 'yank', label(r))
    }
    if (options.purge) await this.env.BUCKET.delete(rows.map((r) => r.filename))

    const gen = await this.rebuild(`${options.purge ? 'purge' : 'yank'} ${pkg} ${version}`)
    return { ok: true, value: { gen, removed: rows.map(label) } }
  }

  async setMeta(pkg: string, patch: Omit<PackageMeta, 'package' | 'updatedAt'>, actor: string): Promise<Result<PackageMeta>> {
    if (this.records({ package: pkg, includeYanked: true }).length === 0) {
      return { ok: false, status: 404, detail: `找不到包 ${pkg}` }
    }
    const merged: PackageMeta = { ...this.meta().get(pkg), ...patch, package: pkg, updatedAt: Date.now() }
    this.sql.exec(
      'INSERT OR REPLACE INTO meta (package, data, updated_at) VALUES (?, ?, ?)',
      pkg,
      JSON.stringify(merged),
      merged.updatedAt,
    )
    this.audit(actor, 'meta', pkg, JSON.stringify(patch))
    await this.rebuild(`meta ${pkg}`)
    return { ok: true, value: merged }
  }

  // 每个包的最新在架版本
  async listPackages(): Promise<{ package: string; latest: PackageRecord; meta?: PackageMeta }[]> {
    const meta = this.meta()
    const latest = new Map<string, PackageRecord>()
    for (const r of this.records()) {
      const prev = latest.get(r.package)
      if (!prev || compareVersions(r.version, prev.version) > 0) latest.set(r.package, r)
    }
    return [...latest.values()].map((r) => ({ package: r.package, latest: r, meta: meta.get(r.package) }))
  }

  async getPackage(pkg: string): Promise<Result<{ meta?: PackageMeta; versions: PackageRecord[] }>> {
    const versions = this.records({ package: pkg, includeYanked: true })
    if (versions.length === 0) return { ok: false, status: 404, detail: `找不到包 ${pkg}` }
    return { ok: true, value: { meta: this.meta().get(pkg), versions } }
  }

  async listSnapshots(): Promise<SnapshotInfo[]> {
    return this.sql
      .exec<{ gen: number; created_at: number; reason: string; entries: string; packages_sha256: string }>(
        'SELECT * FROM snapshots ORDER BY gen DESC',
      )
      .toArray()
      .map((s) => ({
        gen: s.gen,
        createdAt: s.created_at,
        reason: s.reason,
        entries: (JSON.parse(s.entries) as string[]).length,
        packagesSha256: s.packages_sha256,
      }))
  }

  // 回滚：把在架版本恢复成快照 gen 时的集合，然后生成一个新快照
  async rollback(gen: number, actor: string): Promise<Result<{ gen: number }>> {
    const row = this.sql.exec<{ entries: string }>('SELECT entries FROM snapshots WHERE gen = ?', gen).toArray()[0]
    if (!row) return { ok: false, status: 404, detail: `找不到快照 ${gen}` }

    const wanted = new Set(JSON.parse(row.entries) as string[])
    for (const r of this.records({ includeYanked: true })) {
      this.sql.exec(
        'UPDATE packages SET yanked = ? WHERE package = ? AND version = ? AND arch = ?',
        wanted.has(key(r)) ? 0 : 1,
        r.package,
        r.version,
        r.arch,
      )
    }
    this.audit(actor, 'rollback', String(gen))
    return { ok: true, value: { gen: await this.rebuild(`rollback to ${gen}`) } }
  }

  // 手动全量重建（API 调用）
  async rebuildManually(actor: string): Promise<{ gen: number }> {
    this.audit(actor, 'rebuild', 'index')
    return { gen: await this.rebuild('manual rebuild') }
  }

  // 根据当前数据库重新生成全部索引与描述页，返回新快照编号
  private async rebuild(reason: string): Promise<number> {
    const config = repoConfig(this.env)
    const records = this.records()
    const meta = this.meta()
    const snapshot = await buildSnapshot(records, meta, config)
    const gen = this.currentGen() + 1

    await writeSnapshot(this.env.BUCKET, gen, snapshot.files)
    await writeDepictions(this.env.BUCKET, records, meta, config)
    this.sql.exec(
      'INSERT INTO snapshots (gen, created_at, reason, entries, packages_sha256) VALUES (?, ?, ?, ?, ?)',
      gen,
      Date.now(),
      reason,
      JSON.stringify(records.map(key)),
      snapshot.packagesSha256,
    )

    // 只保留最近 SNAPSHOT_KEEP 份快照
    const stale = this.sql
      .exec<{ gen: number }>('SELECT gen FROM snapshots ORDER BY gen DESC LIMIT -1 OFFSET ?', SNAPSHOT_KEEP)
      .toArray()
      .map((s) => s.gen)
    if (stale.length) {
      await deleteSnapshots(this.env.BUCKET, stale)
      this.sql.exec(`DELETE FROM snapshots WHERE gen IN (${stale.map(() => '?').join(',')})`, ...stale)
    }
    return gen
  }


  private currentGen(): number {
    return this.sql.exec<{ gen: number | null }>('SELECT MAX(gen) AS gen FROM snapshots').one().gen ?? 0
  }

  private findRecord(pkg: string, version: string, arch: string): PackageRecord | undefined {
    return this.records({ package: pkg, version, arch, includeYanked: true })[0]
  }

  private records(filter: { package?: string; version?: string; arch?: string; includeYanked?: boolean } = {}): PackageRecord[] {
    const where: string[] = []
    const params: unknown[] = []
    if (!filter.includeYanked) where.push('yanked = 0')
    for (const col of ['package', 'version', 'arch'] as const) {
      if (filter[col] !== undefined) {
        where.push(`${col} = ?`)
        params.push(filter[col])
      }
    }
    const clause = where.length ? `WHERE ${where.join(' AND ')}` : ''
    return this.sql
      .exec<PackageRow>(`SELECT * FROM packages ${clause} ORDER BY package, published_at`, ...params)
      .toArray()
      .map(toRecord)
  }

  private meta(): Map<string, PackageMeta> {
    const rows = this.sql.exec<{ package: string; data: string }>('SELECT package, data FROM meta').toArray()
    return new Map(rows.map((r) => [r.package, JSON.parse(r.data) as PackageMeta]))
  }

  private audit(actor: string, action: string, target: string, detail?: string): void {
    this.sql.exec(
      'INSERT INTO audit (at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)',
      Date.now(),
      actor,
      action,
      target,
      detail ?? null,
    )
  }
}

function toRecord(row: PackageRow): PackageRecord {
  return {
    package: row.package,
    version: row.version,
    arch: row.arch,
    filename: row.filename,
    size: row.size,
    md5: row.md5,
    sha1: row.sha1,
    sha256: row.sha256,
    control: JSON.parse(row.control),
    changelog: row.changelog,
    yanked: row.yanked === 1,
    publishedAt: row.published_at,
    actor: row.actor,
  }
}

function key(r: { package: string; version: string; arch: string }): string {
  return `${r.package}|${r.version}|${r.arch}`
}

function label(r: { package: string; version: string; arch: string }): string {
  return `${r.package} ${r.version} (${r.arch})`
}
