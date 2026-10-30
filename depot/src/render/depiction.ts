import { field } from '../deb'
import type { PackageMeta, PackageRecord, RepoConfig } from '../env'
import { absolute, sortRecords } from './packages'

// 描述页数据：由元数据 + 该包所有未下架版本（旧 → 新）生成
export interface DepictionInput {
  meta: PackageMeta | undefined
  records: PackageRecord[]
}

// 中性灰：Sileo 只接受一个 tintColor，浅色和深色模式下都要清晰
const TINT = '#8e8e93'
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
