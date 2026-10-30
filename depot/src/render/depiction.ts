import { field } from '../deb'
import type { PackageMeta, PackageRecord, RepoConfig } from '../env'
import { absolute, sortRecords } from './packages'

// 描述页数据：由元数据 + 该包所有未下架版本（旧 → 新）生成
export interface DepictionInput {
  meta: PackageMeta | undefined
  records: PackageRecord[]
}

const TINT = '#5b6cf9'
const CHANGELOG_LIMIT = 10

function summarize({ meta, records }: DepictionInput, config: RepoConfig) {
  const sorted = sortRecords(records)
  const latest = sorted.at(-1)!
  const description = field(latest.control, 'Description') ?? ''
  const [summary = '', ...long] = description.split('\n')
  // 同一版本可能有多个架构，changelog 按版本去重
  const versions = [...new Map(sorted.map((r) => [r.version, r])).values()].reverse()
  return {
    pkg: latest.package,
    name: meta?.name ?? field(latest.control, 'Name') ?? latest.package,
    author: field(latest.control, 'Author') ?? field(latest.control, 'Maintainer') ?? '',
    version: latest.version,
    summary,
    details: long.join('\n').trim(),
    archs: [...new Set(sorted.filter((r) => r.version === latest.version).map((r) => r.arch))],
    compat: compatibility(meta),
    screenshots: (meta?.screenshots ?? []).map((s) => absolute(s, config)),
    header: meta?.header ? absolute(meta.header, config) : undefined,
    sourceUrl: meta?.sourceUrl,
    changelog: versions.slice(0, CHANGELOG_LIMIT).map((r) => ({
      version: r.version,
      date: new Date(r.publishedAt).toISOString().slice(0, 10),
      text: r.changelog ?? '',
    })),
  }
}

function compatibility(meta: PackageMeta | undefined): string | undefined {
  if (!meta?.minIos && !meta?.maxIos) return undefined
  return `iOS ${meta.minIos ?? '?'} – ${meta.maxIos ?? '?'}`
}

const ARCH_LABEL: Record<string, string> = {
  'iphoneos-arm64e': 'roothide',
  'iphoneos-arm64': 'rootless',
  'iphoneos-arm': 'rootful',
}

// Sileo 原生描述页
export function renderSileoDepiction(input: DepictionInput, config: RepoConfig): string {
  const d = summarize(input, config)
  const details: unknown[] = [
    { class: 'DepictionMarkdownView', markdown: [d.summary, d.details].filter(Boolean).join('\n\n'), useSpacing: true },
  ]
  if (d.screenshots.length) {
    details.push({
      class: 'DepictionScreenshotsView',
      itemCornerRadius: 8,
      itemSize: '{160, 346}',
      screenshots: d.screenshots.map((url) => ({ url, accessibilityText: 'Screenshot' })),
    })
  }
  details.push(
    { class: 'DepictionSeparatorView' },
    { class: 'DepictionTableTextView', title: 'Version', text: d.version },
    { class: 'DepictionTableTextView', title: 'Author', text: d.author },
    { class: 'DepictionTableTextView', title: 'Jailbreak', text: d.archs.map((a) => ARCH_LABEL[a] ?? a).join(', ') },
  )
  if (d.compat) details.push({ class: 'DepictionTableTextView', title: 'Compatibility', text: d.compat })
  if (d.sourceUrl) {
    details.push({ class: 'DepictionTableButtonView', title: 'Source Code', action: d.sourceUrl, openExternal: true })
  }

  const changelog = d.changelog.flatMap((c) => [
    { class: 'DepictionSubheaderView', title: `${c.version} · ${c.date}`, useBoldText: true },
    { class: 'DepictionMarkdownView', markdown: c.text || '—', useSpacing: true },
  ])

  return JSON.stringify(
    {
      minVersion: '0.1',
      class: 'DepictionTabView',
      tintColor: TINT,
      ...(d.header ? { headerImage: d.header } : {}),
      tabs: [
        { tabname: 'Details', class: 'DepictionStackView', views: details },
        { tabname: 'Changelog', class: 'DepictionStackView', views: changelog },
      ],
    },
    null,
    2,
  )
}

// Zebra / Cydia / 浏览器使用的 HTML 描述页
export function renderHtmlDepiction(input: DepictionInput, config: RepoConfig): string {
  const d = summarize(input, config)
  const rows: [string, string][] = [
    ['Version', d.version],
    ['Author', d.author],
    ['Jailbreak', d.archs.map((a) => ARCH_LABEL[a] ?? a).join(', ')],
  ]
  if (d.compat) rows.push(['Compatibility', d.compat])

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(d.name)}</title>
<style>
:root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --fg: #1c1c1e; --muted: #6e6e73; --tint: ${TINT}; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --fg: #f2f2f7; --muted: #98989f; } }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
.card { background: var(--card); border-radius: 12px; padding: 14px 16px; margin-bottom: 14px; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 13px; text-transform: uppercase; color: var(--muted); margin: 0 0 8px; }
p { margin: 0 0 8px; white-space: pre-wrap; } .muted { color: var(--muted); }
.shots { display: flex; gap: 10px; overflow-x: auto; } .shots img { height: 320px; border-radius: 8px; }
table { width: 100%; border-collapse: collapse; } td { padding: 6px 0; } td:last-child { text-align: right; color: var(--muted); }
tr + tr td { border-top: 1px solid color-mix(in srgb, var(--muted) 25%, transparent); }
a { color: var(--tint); } .log + .log { margin-top: 10px; }
</style>
</head>
<body>
<div class="card"><h1>${esc(d.name)}</h1><p class="muted">${esc(d.summary)}</p>${d.details ? `<p>${esc(d.details)}</p>` : ''}</div>
${d.screenshots.length ? `<div class="card shots">${d.screenshots.map((s) => `<img src="${esc(s)}" alt="Screenshot">`).join('')}</div>` : ''}
<div class="card"><h2>Information</h2><table>${rows.map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('')}</table>${
    d.sourceUrl ? `<p style="margin-top:8px"><a href="${esc(d.sourceUrl)}">Source Code</a></p>` : ''
  }</div>
<div class="card"><h2>Changelog</h2>${d.changelog
    .map((c) => `<div class="log"><strong>${esc(c.version)}</strong> <span class="muted">${c.date}</span><p>${esc(c.text || '—')}</p></div>`)
    .join('')}</div>
</body>
</html>
`
}

function esc(text: string): string {
  return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
}
