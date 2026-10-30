// ar 归档解析：.deb 外层就是一个 ar 包，依次包含 debian-binary、control.tar.*、data.tar.*

export interface ArEntry {
  name: string
  data: Uint8Array
}

const MAGIC = '!<arch>\n'
const HEADER_SIZE = 60

const decoder = new TextDecoder('ascii')

export function parseAr(bytes: Uint8Array): ArEntry[] {
  if (bytes.length < MAGIC.length || decoder.decode(bytes.subarray(0, MAGIC.length)) !== MAGIC) {
    throw new DebFormatError('不是有效的 ar 归档（缺少 !<arch> 头）')
  }

  const entries: ArEntry[] = []
  let offset = MAGIC.length
  while (offset + HEADER_SIZE <= bytes.length) {
    const header = bytes.subarray(offset, offset + HEADER_SIZE)
    // 每个成员头以 "`\n" 结尾
    if (header[58] !== 0x60 || header[59] !== 0x0a) {
      throw new DebFormatError(`ar 成员头损坏（偏移 ${offset}）`)
    }
    // GNU ar 会在文件名末尾加 "/"
    const name = decoder.decode(header.subarray(0, 16)).trim().replace(/\/$/, '')
    const size = Number.parseInt(decoder.decode(header.subarray(48, 58)).trim(), 10)
    if (!Number.isFinite(size) || size < 0) {
      throw new DebFormatError(`ar 成员 ${name} 的大小无效`)
    }

    const start = offset + HEADER_SIZE
    const end = start + size
    if (end > bytes.length) {
      throw new DebFormatError(`ar 成员 ${name} 被截断`)
    }
    entries.push({ name, data: bytes.subarray(start, end) })
    // 成员数据按 2 字节对齐
    offset = end + (size % 2)
  }
  return entries
}

export class DebFormatError extends Error {
  override name = 'DebFormatError'
}
