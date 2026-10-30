import { ARCHITECTURES, digest } from '../deb'
import type { RepoConfig } from '../env'

export interface IndexFile {
  name: string
  bytes: Uint8Array
}

// 生成 flat repo 的 Release，列出各索引文件的大小与哈希
export async function renderRelease(files: IndexFile[], config: RepoConfig, date = new Date()): Promise<string> {
  const sums = await Promise.all(files.map(async (f) => ({ name: f.name, ...(await digest(f.bytes)) })))
  const section = (title: string, key: 'md5' | 'sha1' | 'sha256') =>
    [`${title}:`, ...sums.map((s) => ` ${s[key]} ${String(s.size).padStart(8)} ${s.name}`)].join('\n')

  return (
    [
      `Origin: ${config.label}`,
      `Label: ${config.label}`,
      'Suite: stable',
      'Version: 1.0',
      'Codename: ios',
      `Date: ${date.toUTCString()}`,
      `Architectures: ${ARCHITECTURES.join(' ')}`,
      'Components: main',
      `Description: ${config.description}`,
      section('MD5Sum', 'md5'),
      section('SHA1', 'sha1'),
      section('SHA256', 'sha256'),
    ].join('\n') + '\n'
  )
}
