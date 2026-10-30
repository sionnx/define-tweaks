import { DebFormatError, parseAr } from './ar'
import { type Control, parseControl } from './control'
import { decompressMember } from './decompress'
import { findTarFile } from './tar'

export { DebFormatError } from './ar'
export { type Control, field, parseControl, serializeControl } from './control'
export { UnsupportedCompressionError } from './decompress'
export { ARCHITECTURES, type Architecture, ControlValidationError, type PackageIdentity, validateControl } from './validate'
export { compareVersions } from './version'

export interface Digests {
  size: number
  md5: string
  sha1: string
  sha256: string
}

export interface InspectedDeb extends Digests {
  control: Control
}

// Parse a .deb: extract the control paragraph and compute its hashes
export async function inspectDeb(bytes: Uint8Array): Promise<InspectedDeb> {
  const entries = parseAr(bytes)
  if (entries[0]?.name !== 'debian-binary') throw new DebFormatError('The first member must be debian-binary')

  const member = entries.find((e) => e.name.startsWith('control.tar'))
  if (!member) throw new DebFormatError('control.tar.* not found')

  const tar = await decompressMember(member.name, member.data)
  const file = findTarFile(tar, './control')
  if (!file) throw new DebFormatError('No control file in control.tar')

  const control = parseControl(new TextDecoder().decode(file))
  return { control, ...(await digest(bytes)) }
}

export async function digest(bytes: Uint8Array): Promise<Digests> {
  // Workers' crypto.subtle also supports MD5, which the MD5sum field in Packages needs
  const [md5, sha1, sha256] = await Promise.all(
    (['MD5', 'SHA-1', 'SHA-256'] as const).map(async (alg) => hex(await crypto.subtle.digest(alg, bytes))),
  )
  return { size: bytes.byteLength, md5: md5!, sha1: sha1!, sha256: sha256! }
}

export function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
