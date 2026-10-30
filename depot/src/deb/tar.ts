import { DebFormatError } from './ar'

// 极简 tar 读取：只为从 control.tar 里找出 ./control 文件，不处理链接、权限等

const BLOCK = 512
const decoder = new TextDecoder()

export function findTarFile(bytes: Uint8Array, wanted: string): Uint8Array | undefined {
  let offset = 0
  let longName: string | undefined

  while (offset + BLOCK <= bytes.length) {
    const header = bytes.subarray(offset, offset + BLOCK)
    // 连续的全零块表示归档结束
    if (header.every((b) => b === 0)) return undefined

    const size = parseOctal(header.subarray(124, 136))
    const type = String.fromCharCode(header[156] ?? 0)
    const dataStart = offset + BLOCK
    const dataEnd = dataStart + size
    if (dataEnd > bytes.length) throw new DebFormatError('tar 成员被截断')

    if (type === 'L') {
      // GNU 长文件名：下一个成员的真实名字存在本成员数据里
      longName = cString(bytes.subarray(dataStart, dataEnd))
    } else {
      const prefix = cString(header.subarray(345, 500))
      const name = longName ?? (prefix ? `${prefix}/` : '') + cString(header.subarray(0, 100))
      longName = undefined
      if ((type === '0' || type === '\0') && normalize(name) === normalize(wanted)) {
        return bytes.subarray(dataStart, dataEnd)
      }
    }
    offset = dataStart + Math.ceil(size / BLOCK) * BLOCK
  }
  return undefined
}

function cString(bytes: Uint8Array): string {
  const end = bytes.indexOf(0)
  return decoder.decode(end === -1 ? bytes : bytes.subarray(0, end))
}

function parseOctal(bytes: Uint8Array): number {
  const text = cString(bytes).trim()
  return text ? Number.parseInt(text, 8) : 0
}

// "./control" 与 "control" 视为同一个文件
function normalize(path: string): string {
  return path.replace(/^\.\//, '')
}
