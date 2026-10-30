// dpkg version comparison, matching `dpkg --compare-versions`
// Version format: [epoch:]upstream[-revision]

interface ParsedVersion {
  epoch: number
  upstream: string
  revision: string
}

export function parseVersion(version: string): ParsedVersion {
  let rest = version.trim()
  let epoch = 0
  const colon = rest.indexOf(':')
  if (colon !== -1) {
    epoch = Number.parseInt(rest.slice(0, colon), 10)
    if (!Number.isInteger(epoch) || epoch < 0) throw new Error(`Invalid epoch in version: ${version}`)
    rest = rest.slice(colon + 1)
  }
  // The revision is everything after the last "-"
  const dash = rest.lastIndexOf('-')
  const upstream = dash === -1 ? rest : rest.slice(0, dash)
  const revision = dash === -1 ? '' : rest.slice(dash + 1)
  return { epoch, upstream, revision }
}

// upstream must start with a digit, and only characters dpkg accepts are allowed
export function isValidVersion(version: string): boolean {
  return /^(?:\d+:)?[0-9][A-Za-z0-9.+~-]*$/.test(version)
}

// Returns a negative number / 0 / a positive number, usable directly with Array.prototype.sort
export function compareVersions(a: string, b: string): number {
  const va = parseVersion(a)
  const vb = parseVersion(b)
  if (va.epoch !== vb.epoch) return va.epoch - vb.epoch
  return compareFragment(va.upstream, vb.upstream) || compareFragment(va.revision, vb.revision)
}

// Character sort weight: ~ sorts lowest (even before the end of the string), letters before non-letters
function order(char: string | undefined): number {
  if (char === undefined) return 0
  if (char === '~') return -1
  if (/[0-9]/.test(char)) return 0
  if (/[A-Za-z]/.test(char)) return char.charCodeAt(0)
  return char.charCodeAt(0) + 256
}

function compareFragment(a: string, b: string): number {
  let i = 0
  let j = 0
  while (i < a.length || j < b.length) {
    // Compare the non-digit part character by character first
    let diff = 0
    while ((i < a.length && !isDigit(a[i])) || (j < b.length && !isDigit(b[j]))) {
      const ac = order(i < a.length && !isDigit(a[i]) ? a[i] : undefined)
      const bc = order(j < b.length && !isDigit(b[j]) ? b[j] : undefined)
      if (ac !== bc) return ac - bc
      if (i < a.length && !isDigit(a[i])) i++
      if (j < b.length && !isDigit(b[j])) j++
    }
    // Then compare the digit part numerically (ignoring leading zeros)
    while (a[i] === '0') i++
    while (b[j] === '0') j++
    while (isDigit(a[i]) && isDigit(b[j])) {
      if (!diff) diff = a.charCodeAt(i) - b.charCodeAt(j)
      i++
      j++
    }
    if (isDigit(a[i])) return 1
    if (isDigit(b[j])) return -1
    if (diff) return diff
  }
  return 0
}

function isDigit(char: string | undefined): boolean {
  return char !== undefined && char >= '0' && char <= '9'
}
