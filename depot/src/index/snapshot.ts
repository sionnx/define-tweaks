import { gzip } from '../deb/decompress'
import { digest } from '../deb/index'
import type { PackageMeta, PackageRecord, RepoConfig } from '../env'
import { renderSileoDepiction } from '../render/depiction'
import { renderPackages } from '../render/packages'
import { type IndexFile, renderRelease } from '../render/release'

export const SNAPSHOT_KEEP = 20

// Index files read by clients; Release must be written to the root last
export const INDEX_FILES = ['Packages', 'Packages.gz', 'Release'] as const

const CONTENT_TYPE: Record<string, string> = {
  Packages: 'text/plain; charset=utf-8',
  'Packages.gz': 'application/gzip',
  Release: 'text/plain; charset=utf-8',
}

export interface Snapshot {
  files: IndexFile[]
  packagesSha256: string
}

export async function buildSnapshot(
  records: PackageRecord[],
  meta: Map<string, PackageMeta>,
  config: RepoConfig,
): Promise<Snapshot> {
  const packages = new TextEncoder().encode(renderPackages(records, meta, config))
  const files: IndexFile[] = [
    { name: 'Packages', bytes: packages },
    { name: 'Packages.gz', bytes: await gzip(packages) },
  ]
  const release = await renderRelease(files, config)
  files.push({ name: 'Release', bytes: new TextEncoder().encode(release) })
  return { files, packagesSha256: (await digest(packages)).sha256 }
}

// Archive to snapshots/<gen>/ first, then overwrite the root in Packages* → Release order
export async function writeSnapshot(bucket: R2Bucket, gen: number, files: IndexFile[]): Promise<void> {
  await Promise.all(files.map((f) => bucket.put(`snapshots/${gen}/${f.name}`, f.bytes, meta(f.name))))
  await activate(bucket, files)
}

async function activate(bucket: R2Bucket, files: IndexFile[]): Promise<void> {
  const ordered = [...files].sort((a, b) => Number(a.name === 'Release') - Number(b.name === 'Release'))
  for (const f of ordered) await bucket.put(f.name, f.bytes, meta(f.name))
}

export async function deleteSnapshots(bucket: R2Bucket, gens: number[]): Promise<void> {
  const keys = gens.flatMap((gen) => INDEX_FILES.map((name) => `snapshots/${gen}/${name}`))
  if (keys.length) await bucket.delete(keys)
}

// Regenerate depictions (native Sileo JSON only) for every package that still has a listed version
export async function writeDepictions(
  bucket: R2Bucket,
  records: PackageRecord[],
  meta: Map<string, PackageMeta>,
  config: RepoConfig,
): Promise<void> {
  const byPackage = Map.groupBy(records, (r) => r.package)
  await Promise.all(
    [...byPackage].flatMap(([pkg, list]) => {
      const input = { meta: meta.get(pkg), records: list }
      return [
        bucket.put(`depictions/${pkg}.json`, renderSileoDepiction(input, config), {
          httpMetadata: { contentType: 'application/json; charset=utf-8' },
        }),
        // Clean up previously generated HTML depictions
        bucket.delete(`depictions/${pkg}.html`),
      ]
    }),
  )
}

function meta(name: string): R2PutOptions {
  return { httpMetadata: { contentType: CONTENT_TYPE[name] ?? 'application/octet-stream' } }
}
