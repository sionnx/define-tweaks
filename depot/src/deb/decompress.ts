import { DebFormatError } from './ar'

// Decompress control.tar.* based on the ar member name suffix.
// Only gzip and uncompressed are supported for now (Theos produces control.tar.gz); xz / zst are left as extension points
export async function decompressMember(name: string, data: Uint8Array): Promise<Uint8Array> {
  if (name.endsWith('.tar')) return data
  if (name.endsWith('.tar.gz')) return gunzip(data)
  throw new UnsupportedCompressionError(`Unsupported compression for ${name}; build control with gzip`)
}

export async function gunzip(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('gzip'))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

export async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new CompressionStream('gzip'))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

export class UnsupportedCompressionError extends DebFormatError {
  override name = 'UnsupportedCompressionError'
}
