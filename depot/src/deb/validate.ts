import { type Control, field } from './control'
import { isValidVersion } from './version'

// Architectures for the roothide / rootless / rootful jailbreak schemes
export const ARCHITECTURES = ['iphoneos-arm64e', 'iphoneos-arm64', 'iphoneos-arm'] as const
export type Architecture = (typeof ARCHITECTURES)[number]

const REQUIRED = ['Package', 'Version', 'Architecture', 'Maintainer', 'Description'] as const
const PACKAGE_RE = /^[a-z0-9][a-z0-9.+-]+$/

export interface ValidateOptions {
  // Theos debug packages (versions containing +debug) are rejected by default
  allowDebug?: boolean
}

export interface PackageIdentity {
  package: string
  version: string
  arch: Architecture
}

export function validateControl(control: Control, options: ValidateOptions = {}): PackageIdentity {
  const problems: string[] = []
  for (const name of REQUIRED) {
    if (!field(control, name)) problems.push(`Missing required field ${name}`)
  }

  const pkg = field(control, 'Package') ?? ''
  const version = field(control, 'Version') ?? ''
  const arch = field(control, 'Architecture') ?? ''

  if (pkg && !PACKAGE_RE.test(pkg)) problems.push(`Invalid package name ${pkg}: only lowercase letters, digits and . + - are allowed`)
  if (version && !isValidVersion(version)) problems.push(`Invalid version ${version}`)
  if (version && !options.allowDebug && /\+debug\b/.test(version)) {
    problems.push(`Version ${version} is a debug build; package with FINALPACKAGE=1`)
  }
  if (arch && !(ARCHITECTURES as readonly string[]).includes(arch)) {
    problems.push(`Unsupported architecture ${arch}; expected one of: ${ARCHITECTURES.join(', ')}`)
  }

  if (problems.length > 0) throw new ControlValidationError(problems)
  return { package: pkg, version, arch: arch as Architecture }
}

export class ControlValidationError extends Error {
  override name = 'ControlValidationError'
  constructor(readonly problems: string[]) {
    super(problems.join('; '))
  }
}
