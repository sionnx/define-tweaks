import { DebFormatError } from './ar'

// control 段落：字段名 → 值，保持原始顺序；多行值（如 Description 的长描述）用 "\n" 连接，续行不含前导空格
export type Control = Record<string, string>

export function parseControl(text: string): Control {
  const control: Control = {}
  let current: string | undefined

  for (const raw of text.replace(/\r\n/g, '\n').split('\n')) {
    if (raw.trim() === '') {
      // 只解析第一个段落
      if (Object.keys(control).length > 0) break
      continue
    }
    if (raw.startsWith('#')) continue

    if (raw.startsWith(' ') || raw.startsWith('\t')) {
      if (!current) throw new DebFormatError(`control 续行前没有字段：${raw}`)
      const line = raw.slice(1)
      control[current] += '\n' + (line === '.' ? '' : line)
      continue
    }

    const colon = raw.indexOf(':')
    if (colon <= 0) throw new DebFormatError(`control 行格式错误：${raw}`)
    current = raw.slice(0, colon).trim()
    control[current] = raw.slice(colon + 1).trim()
  }
  return control
}

// 序列化为 Packages / control 文本（不含结尾空行）
export function serializeControl(control: Control): string {
  return Object.entries(control)
    .filter(([, value]) => value !== '')
    .map(([key, value]) => {
      const [first, ...rest] = value.split('\n')
      // 续行以空格开头；空行按 Debian 规范写成 " ."
      return [`${key}: ${first}`, ...rest.map((line) => ` ${line === '' ? '.' : line}`)].join('\n')
    })
    .join('\n')
}

// 字段名大小写不敏感
export function field(control: Control, name: string): string | undefined {
  const lower = name.toLowerCase()
  for (const [key, value] of Object.entries(control)) {
    if (key.toLowerCase() === lower) return value
  }
  return undefined
}
