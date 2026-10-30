// ar archive parsing: a .deb is an ar archive containing debian-binary, control.tar.* and data.tar.*, in that order

export interface ArEntry {
  name: string
  data: Uint8Array
}

const MAGIC = '!<arch>\n'
const HEADER_SIZE = 60

const decoder = new TextDecoder('ascii')

export function parseAr(bytes: Uint8Array): ArEntry[] {
  if (bytes.length < MAGIC.length || decoder.decode(bytes.subarray(0, MAGIC.length)) !== MAGIC) {
    throw new DebFormatError('Not a valid ar archive (missing !<arch> header)')
  }

  const entries: ArEntry[] = []
  let offset = MAGIC.length
  while (offset + HEADER_SIZE <= bytes.length) {
    const header = bytes.subarray(offset, offset + HEADER_SIZE)
    // Every member header ends with "`\n"
    if (header[58] !== 0x60 || header[59] !== 0x0a) {
      throw new DebFormatError(`Corrupt ar member header at offset ${offset}`)
    }
    // GNU ar appends "/" to member names
    const name = decoder.decode(header.subarray(0, 16)).trim().replace(/\/$/, '')
    const size = Number.parseInt(decoder.decode(header.subarray(48, 58)).trim(), 10)
    if (!Number.isFinite(size) || size < 0) {
      throw new DebFormatError(`Invalid size for ar member ${name}`)
    }

    const start = offset + HEADER_SIZE
    const end = start + size
    if (end > bytes.length) {
      throw new DebFormatError(`ar member ${name} is truncated`)
    }
    entries.push({ name, data: bytes.subarray(start, end) })
    // Member data is 2-byte aligned
    offset = end + (size % 2)
  }
  return entries
}

export class DebFormatError extends Error {
  override name = 'DebFormatError'
}
