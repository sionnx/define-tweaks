// dpkg 版本比较，与 `dpkg --compare-versions` 行为一致
// 版本格式：[epoch:]upstream[-revision]

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
    if (!Number.isInteger(epoch) || epoch < 0) throw new Error(`版本号 epoch 无效：${version}`)
    rest = rest.slice(colon + 1)
  }
  // revision 取最后一个 "-" 之后的部分
  const dash = rest.lastIndexOf('-')
  const upstream = dash === -1 ? rest : rest.slice(0, dash)
  const revision = dash === -1 ? '' : rest.slice(dash + 1)
  return { epoch, upstream, revision }
}

// upstream 必须以数字开头，整体只允许 dpkg 认可的字符
export function isValidVersion(version: string): boolean {
  return /^(?:\d+:)?[0-9][A-Za-z0-9.+~-]*$/.test(version)
}

// 返回负数 / 0 / 正数，可直接用于 Array.prototype.sort
export function compareVersions(a: string, b: string): number {
  const va = parseVersion(a)
  const vb = parseVersion(b)
  if (va.epoch !== vb.epoch) return va.epoch - vb.epoch
  return compareFragment(va.upstream, vb.upstream) || compareFragment(va.revision, vb.revision)
}

// 字符排序权重：~ 最小（比空还小），字母在非字母符号之前
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
    // 先逐字符比较非数字部分
    let diff = 0
    while ((i < a.length && !isDigit(a[i])) || (j < b.length && !isDigit(b[j]))) {
      const ac = order(i < a.length && !isDigit(a[i]) ? a[i] : undefined)
      const bc = order(j < b.length && !isDigit(b[j]) ? b[j] : undefined)
      if (ac !== bc) return ac - bc
      if (i < a.length && !isDigit(a[i])) i++
      if (j < b.length && !isDigit(b[j])) j++
    }
    // 再按数值比较数字部分（忽略前导零）
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
