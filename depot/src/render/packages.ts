import { compareVersions, serializeControl } from '../deb'
import type { PackageMeta, PackageRecord, RepoConfig } from '../env'

// 由服务端生成、会覆盖 deb 自带同名字段的字段
// 不生成 HTML 描述页，deb 自带的 Depiction 也一并去掉，避免指向无效或过时的页面
const GENERATED = new Set(['filename', 'size', 'md5sum', 'sha1', 'sha256', 'icon', 'depiction', 'sileodepiction', 'header'])

export function sortRecords(records: PackageRecord[]): PackageRecord[] {
  return [...records].sort(
    (a, b) =>
      a.package.localeCompare(b.package) || compareVersions(a.version, b.version) || a.arch.localeCompare(b.arch),
  )
}

export function renderPackages(records: PackageRecord[], meta: Map<string, PackageMeta>, config: RepoConfig): string {
  const stanzas = sortRecords(records).map((record) => {
    const info = meta.get(record.package)
    const control: Record<string, string> = {}
    for (const [key, value] of Object.entries(record.control)) {
      if (!GENERATED.has(key.toLowerCase())) control[key] = value
    }
    if (info?.name) control.Name = info.name

    control.Filename = record.filename
    control.Size = String(record.size)
    control.MD5sum = record.md5
    control.SHA1 = record.sha1
    control.SHA256 = record.sha256
    if (info?.icon) control.Icon = absolute(info.icon, config)
    if (info?.header) control.Header = absolute(info.header, config)
    control.SileoDepiction = `${config.publicUrl}/depictions/${record.package}.json`
    return serializeControl(control)
  })
  return stanzas.length ? stanzas.join('\n\n') + '\n' : ''
}

// 元数据里的图片可以是相对 R2 的 key，也可以是完整 URL
export function absolute(pathOrUrl: string, config: RepoConfig): string {
  return /^https?:\/\//.test(pathOrUrl) ? pathOrUrl : `${config.publicUrl}/${pathOrUrl.replace(/^\//, '')}`
}
