import { DebFormatError } from './ar'

// 按 ar 成员名后缀解压 control.tar.*
// 目前只支持 gzip 和不压缩（Theos 默认产物即 control.tar.gz），xz / zst 留作扩展点
export async function decompressMember(name: string, data: Uint8Array): Promise<Uint8Array> {
  if (name.endsWith('.tar')) return data
  if (name.endsWith('.tar.gz')) return gunzip(data)
  throw new UnsupportedCompressionError(`暂不支持 ${name} 的压缩格式，请用 gzip 打包 control`)
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
