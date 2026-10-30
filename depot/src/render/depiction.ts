import { field } from '../deb'
import type { PackageMeta, PackageRecord, RepoConfig } from '../env'
import { absolute, sortRecords } from './packages'

// Depiction input: the package meta plus all of the package's listed versions (oldest → newest)
export interface DepictionInput {
  meta: PackageMeta | undefined
  records: PackageRecord[]
}

// Neutral gray: Sileo takes a single tintColor, which must read well in both light and dark mode
const TINT = '#8e8e93'
const CHANGELOG_LIMIT = 10

function summarize({ meta, records }: DepictionInput, config: RepoConfig) {
  const sorted = sortRecords(records)
  const latest = sorted.at(-1)!
  const description = field(latest.control, 'Description') ?? ''
  const [summary = '', ...long] = description.split('\n')
  // A version may ship several architectures; dedupe the changelog by version
  const versions = [...new Map(sorted.map((r) => [r.version, r])).values()].reverse()
  return {
    pkg: latest.package,
    author: field(latest.control, 'Author') ?? field(latest.control, 'Maintainer') ?? '',
    version: latest.version,
    summary,
    details: long.join('\n').trim(),
    testedOn: meta?.testedOn,
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

// Native Sileo depiction
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
  )
  if (d.testedOn) details.push({ class: 'DepictionTableTextView', title: 'Tested on', text: d.testedOn })
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
