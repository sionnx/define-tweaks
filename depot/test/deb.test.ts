import { describe, expect, it } from 'vitest'
import { compareVersions, inspectDeb, parseControl, serializeControl, validateControl } from '../src/deb'
import { DebFormatError, parseAr } from '../src/deb/ar'
import { UnsupportedCompressionError } from '../src/deb/decompress'
import { isValidVersion } from '../src/deb/version'
import { fixture, sha256 } from './helpers'

describe('inspectDeb', () => {
  it('parses a roothide package built by Theos', async () => {
    const bytes = fixture('dockpages-roothide.deb')
    const deb = await inspectDeb(bytes)
    // Matches the output of `dpkg-deb -f`
    expect(deb.control).toEqual({
      Package: 'to.define.dockpages',
      Name: 'DockPages',
      Description: 'Paged, swipeable dock with 8 icons (2 pages x 4).',
      Maintainer: 'Sion',
      Author: 'Sion',
      Section: 'Tweaks',
      Depends: 'mobilesubstrate (>= 0.9.5000)',
      Architecture: 'iphoneos-arm64e',
      Version: '0.1.0',
    })
    expect(deb.size).toBe(bytes.byteLength)
    expect(deb.sha256).toBe(await sha256(bytes))
    expect(deb.md5).toMatch(/^[0-9a-f]{32}$/)
    expect(deb.sha1).toMatch(/^[0-9a-f]{40}$/)
  })

  it('keeps multi-line descriptions and epoch versions', async () => {
    const { control } = await inspectDeb(fixture('sample-rootless.deb'))
    expect(control.Version).toBe('1:2.0~beta1-3')
    expect(control.Description).toBe('Sample rootless package\nLong description line one.\n\nLine after blank.')
  })

  it('does not support control.tar.xz yet', async () => {
    await expect(inspectDeb(fixture('sample-xz.deb'))).rejects.toBeInstanceOf(UnsupportedCompressionError)
  })

  it('rejects non-ar and truncated files', async () => {
    await expect(inspectDeb(new TextEncoder().encode('hello'))).rejects.toBeInstanceOf(DebFormatError)
    const truncated = fixture('dockpages-roothide.deb').subarray(0, 200)
    expect(() => parseAr(truncated)).toThrow(DebFormatError)
  })
})

describe('control', () => {
  it('round-trips through serialize and parse', () => {
    const control = { Package: 'a.b', Description: 'short\nline one\n\nline three' }
    const text = serializeControl(control)
    expect(text).toBe('Package: a.b\nDescription: short\n line one\n .\n line three')
    expect(parseControl(text)).toEqual(control)
  })
})

describe('validateControl', () => {
  const base = { Package: 'com.a.b', Version: '1.0', Architecture: 'iphoneos-arm64e', Maintainer: 'x', Description: 'd' }

  it('returns the package identity for a valid control', () => {
    expect(validateControl(base)).toEqual({ package: 'com.a.b', version: '1.0', arch: 'iphoneos-arm64e' })
  })

  it('collects every problem', () => {
    expect(() => validateControl({ Package: 'Bad_Name', Version: 'v1', Architecture: 'amd64' })).toThrow(
      /Missing required field Maintainer.*Missing required field Description.*Invalid package name Bad_Name.*Invalid version v1.*Unsupported architecture amd64/,
    )
  })

  it('rejects debug builds by default', () => {
    expect(() => validateControl({ ...base, Version: '0.1.0-1+debug' })).toThrow(/debug build/)
    expect(validateControl({ ...base, Version: '0.1.0-1+debug' }, { allowDebug: true }).version).toBe('0.1.0-1+debug')
  })
})

describe('compareVersions', () => {
  // [a, b, expected sign], matching dpkg --compare-versions
  const cases: [string, string, -1 | 0 | 1][] = [
    ['1.0', '1.0', 0],
    ['1.0', '1.1', -1],
    ['1.0', '1.0.1', -1],
    ['1.10', '1.9', 1],
    ['001', '1', 0],
    ['1.0~rc1', '1.0', -1],
    ['1.0~~', '1.0~', -1],
    ['1.0~', '1.0', -1],
    ['1.0a', '1.0', 1],
    ['1.0+', '1.0', 1],
    ['1.0a', '1.0+', -1],
    ['1:0.1', '2.0', 1],
    ['1.0-1', '1.0-2', -1],
    ['1.0', '1.0-0', 0],
    ['0.1.0-1+debug', '0.1.0', 1],
    ['2.0-1', '2.0~beta1-3', 1],
  ]
  it.each(cases)('%s vs %s', (a, b, expected) => {
    expect(Math.sign(compareVersions(a, b))).toBe(expected)
    expect(Math.sign(compareVersions(b, a))).toBe(-expected || 0)
  })

  it('isValidVersion', () => {
    expect(isValidVersion('1:2.0~beta1-3')).toBe(true)
    expect(isValidVersion('v1.0')).toBe(false)
    expect(isValidVersion('1.0 beta')).toBe(false)
  })
})
