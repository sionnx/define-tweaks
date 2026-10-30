import { DebFormatError } from './ar'

// Minimal tar reader: only finds ./control inside control.tar; links, permissions etc. are ignored

const BLOCK = 512
const decoder = new TextDecoder()

export function findTarFile(bytes: Uint8Array, wanted: string): Uint8Array | undefined {
  let offset = 0
  let longName: string | undefined

  while (offset + BLOCK <= bytes.length) {
    const header = bytes.subarray(offset, offset + BLOCK)
    // An all-zero block marks the end of the archive
    if (header.every((b) => b === 0)) return undefined

    const size = parseOctal(header.subarray(124, 136))
    const type = String.fromCharCode(header[156] ?? 0)
    const dataStart = offset + BLOCK
    const dataEnd = dataStart + size
    if (dataEnd > bytes.length) throw new DebFormatError('tar member is truncated')

    if (type === 'L') {
      // GNU long name: this member's data holds the real name of the next member
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

// "./control" and "control" are the same file
function normalize(path: string): string {
  return path.replace(/^\.\//, '')
}
