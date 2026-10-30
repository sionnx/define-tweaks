import { DebFormatError } from './ar'

// A control paragraph: field name → value, in original order. Multi-line values (e.g. the long Description)
// are joined with "\n", without the continuation lines' leading space
export type Control = Record<string, string>

export function parseControl(text: string): Control {
  const control: Control = {}
  let current: string | undefined

  for (const raw of text.replace(/\r\n/g, '\n').split('\n')) {
    if (raw.trim() === '') {
      // Only the first paragraph is parsed
      if (Object.keys(control).length > 0) break
      continue
    }
    if (raw.startsWith('#')) continue

    if (raw.startsWith(' ') || raw.startsWith('\t')) {
      if (!current) throw new DebFormatError(`Continuation line without a field in control: ${raw}`)
      const line = raw.slice(1)
      control[current] += '\n' + (line === '.' ? '' : line)
      continue
    }

    const colon = raw.indexOf(':')
    if (colon <= 0) throw new DebFormatError(`Malformed control line: ${raw}`)
    current = raw.slice(0, colon).trim()
    control[current] = raw.slice(colon + 1).trim()
  }
  return control
}

// Serialize to Packages / control text (without a trailing blank line)
export function serializeControl(control: Control): string {
  return Object.entries(control)
    .filter(([, value]) => value !== '')
    .map(([key, value]) => {
      const [first, ...rest] = value.split('\n')
      // Continuation lines start with a space; blank lines become " ." per Debian policy
      return [`${key}: ${first}`, ...rest.map((line) => ` ${line === '' ? '.' : line}`)].join('\n')
    })
    .join('\n')
}

// Field names are case-insensitive
export function field(control: Control, name: string): string | undefined {
  const lower = name.toLowerCase()
  for (const [key, value] of Object.entries(control)) {
    if (key.toLowerCase() === lower) return value
  }
  return undefined
}
