import { type Control, field } from './control'
import { isValidVersion } from './version'

// roothide / rootless / rootful 三种越狱方案对应的架构
export const ARCHITECTURES = ['iphoneos-arm64e', 'iphoneos-arm64', 'iphoneos-arm'] as const
export type Architecture = (typeof ARCHITECTURES)[number]

const REQUIRED = ['Package', 'Version', 'Architecture', 'Maintainer', 'Description'] as const
const PACKAGE_RE = /^[a-z0-9][a-z0-9.+-]+$/

export interface ValidateOptions {
  // 默认拒绝 Theos 的调试包（版本号带 +debug）
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
    if (!field(control, name)) problems.push(`缺少必需字段 ${name}`)
  }

  const pkg = field(control, 'Package') ?? ''
  const version = field(control, 'Version') ?? ''
  const arch = field(control, 'Architecture') ?? ''

  if (pkg && !PACKAGE_RE.test(pkg)) problems.push(`包名 ${pkg} 不合法，只允许小写字母、数字和 . + -`)
  if (version && !isValidVersion(version)) problems.push(`版本号 ${version} 不合法`)
  if (version && !options.allowDebug && /\+debug\b/.test(version)) {
    problems.push(`版本号 ${version} 是调试包，请用 FINALPACKAGE=1 打包`)
  }
  if (arch && !(ARCHITECTURES as readonly string[]).includes(arch)) {
    problems.push(`架构 ${arch} 不受支持，可选：${ARCHITECTURES.join(', ')}`)
  }

  if (problems.length > 0) throw new ControlValidationError(problems)
  return { package: pkg, version, arch: arch as Architecture }
}

export class ControlValidationError extends Error {
  override name = 'ControlValidationError'
  constructor(readonly problems: string[]) {
    super(problems.join('；'))
  }
}
