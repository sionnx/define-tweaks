import { reset } from 'cloudflare:test'
import { env, exports } from 'cloudflare:workers'
import { Jwt } from 'hono/utils/jwt'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { gunzip } from '../src/deb/decompress'
import { GITHUB_ISSUER } from '../src/http/auth'
import { ADMIN, fixture, sha256 } from './helpers'

const BASE = 'https://apt.define.to'

// Every test starts from an empty R2 and DO
beforeEach(() => reset())

function call(path: string, init?: RequestInit) {
  return exports.default.fetch(new Request(`${BASE}${path}`, init))
}

function put(bytes: Uint8Array, query = '', headers: HeadersInit = ADMIN) {
  return call(`/api/v1/packages${query}`, { method: 'PUT', headers, body: bytes })
}

async function text(path: string) {
  const res = await call(path)
  expect(res.status, path).toBe(200)
  return res.text()
}

describe('publishing', () => {
  it('publish → index → depiction → meta → yank → rollback', async () => {
    const deb = fixture('dockpages-roothide.deb')
    const debHash = await sha256(deb)

    // First release
    let res = await put(deb, '?changelog=' + encodeURIComponent('First release'))
    expect(res.status).toBe(201)
    const published = await res.json<{ gen: number; created: boolean; url: string; sha256: string }>()
    expect(published).toMatchObject({
      gen: 1,
      created: true,
      sha256: debHash,
      url: `${BASE}/pool/to.define.dockpages/to.define.dockpages_0.1.0_iphoneos-arm64e.deb`,
    })

    // Re-uploading the same file is idempotent and creates no new snapshot
    res = await put(deb)
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ gen: 1, created: false })

    // Packages entry and hashes
    const packages = await text('/Packages')
    expect(packages).toContain('Package: to.define.dockpages\n')
    expect(packages).toContain('Filename: pool/to.define.dockpages/to.define.dockpages_0.1.0_iphoneos-arm64e.deb\n')
    expect(packages).toContain(`SHA256: ${debHash}\n`)
    expect(packages).toContain(`Size: ${deb.byteLength}\n`)
    expect(packages).toContain(`SileoDepiction: ${BASE}/depictions/to.define.dockpages.json`)
    expect(packages).not.toMatch(/^Depiction:/m)

    // Packages.gz decompresses to Packages; the hashes in Release are correct
    const gz = new Uint8Array(await (await call('/Packages.gz')).arrayBuffer())
    expect(new TextDecoder().decode(await gunzip(gz))).toBe(packages)
    const release = await text('/Release')
    const packagesBytes = new TextEncoder().encode(packages)
    expect(release).toContain(`${await sha256(packagesBytes)} ${String(packagesBytes.byteLength).padStart(8)} Packages\n`)
    expect(release).toContain(`${await sha256(gz)} ${String(gz.byteLength).padStart(8)} Packages.gz\n`)
    expect(release).toContain('Architectures: iphoneos-arm64e iphoneos-arm64 iphoneos-arm\n')

    // Depiction
    const sileo = JSON.parse(await text('/depictions/to.define.dockpages.json'))
    expect(sileo.class).toBe('DepictionTabView')
    expect(JSON.stringify(sileo)).toContain('First release')
    // HTML depictions are no longer generated
    expect((await call('/depictions/to.define.dockpages.html')).status).toBe(404)

    // Publish a second package via multipart (rootless, with an epoch) and set its meta at the same time
    const form = new FormData()
    form.append('deb', new File([fixture('sample-rootless.deb')], 'sample.deb'))
    form.append('changelog', 'Beta')
    form.append('meta', JSON.stringify({ name: 'Sample Pro', icon: 'assets/com.example.sample/icon.png', minIos: '15.0', maxIos: '17.3' }))
    res = await call('/api/v1/packages', { method: 'POST', headers: ADMIN, body: form })
    expect(res.status).toBe(201)
    expect(await res.json()).toMatchObject({ version: '1:2.0~beta1-3', arch: 'iphoneos-arm64' })

    const withSample = await text('/Packages')
    expect(withSample).toContain('Name: Sample Pro\n')
    expect(withSample).toContain(`Icon: ${BASE}/assets/com.example.sample/icon.png\n`)
    // The epoch is dropped from the file name
    expect(withSample).toContain('Filename: pool/com.example.sample/com.example.sample_2.0~beta1-3_iphoneos-arm64.deb\n')
    // Multi-line descriptions use the Debian format
    expect(withSample).toContain('Description: Sample rootless package\n Long description line one.\n .\n Line after blank.\n')

    // List endpoint
    const list = await (await call('/api/v1/packages')).json<{ package: string }[]>()
    expect(list.map((p) => p.package)).toEqual(['com.example.sample', 'to.define.dockpages'])

    // Yank sample
    res = await call('/api/v1/packages/com.example.sample/1:2.0~beta1-3', { method: 'DELETE', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).not.toContain('com.example.sample')

    // Roll back to the snapshot that still has sample
    const snapshots = await (await call('/api/v1/index/snapshots', { headers: ADMIN })).json<{ gen: number; entries: number }[]>()
    const target = snapshots.find((s) => s.entries === 2)!
    res = await call(`/api/v1/index/rollback/${target.gen}`, { method: 'POST', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).toContain('Package: com.example.sample\n')

    // purge deletes the records and the file
    res = await call('/api/v1/packages/com.example.sample/1:2.0~beta1-3?purge=1', { method: 'DELETE', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await env.BUCKET.head('pool/com.example.sample/com.example.sample_2.0~beta1-3_iphoneos-arm64.deb')).toBeNull()
    expect((await call('/api/v1/packages/com.example.sample')).status).toBe(404)
  })

  it('returns 409 for the same version with different content; admin can force overwrite', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb)).status).toBe(201)

    // Flip the last byte of the data member: same control, different file content
    const tampered = deb.slice()
    const last = tampered.length - 1
    tampered[last] = tampered[last]! ^ 0xff
    const res = await put(tampered)
    expect(res.status).toBe(409)
    expect(res.headers.get('Content-Type')).toContain('application/problem+json')
    expect(await res.json()).toMatchObject({ status: 409, type: 'https://apt.define.to/errors/version-exists' })

    expect((await put(tampered, '?force=1')).status).toBe(201)
    expect(await text('/Packages')).toContain(`SHA256: ${await sha256(tampered)}`)
  })

  it('rejects debug builds, unsupported compression and non-deb files', async () => {
    let res = await put(fixture('dockpages-debug.deb'))
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ type: 'https://apt.define.to/errors/invalid-control' })
    expect((await put(fixture('dockpages-debug.deb'), '?allowDebug=1')).status).toBe(201)

    res = await put(fixture('sample-xz.deb'))
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ type: 'https://apt.define.to/errors/unsupported-compression' })

    expect((await put(new TextEncoder().encode('not a deb'))).status).toBe(422)
  })

  it('authentication', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb, '', {})).status).toBe(401)
    expect((await put(deb, '', { Authorization: 'Bearer wrong' })).status).toBe(401)
    expect((await call('/api/v1/index/rebuild', { method: 'POST' })).status).toBe(401)
    // Public read-only endpoints need no auth
    expect((await call('/api/v1/packages')).status).toBe(200)
  })

  it('uploads an icon and sets meta via PATCH', async () => {
    expect((await put(fixture('dockpages-roothide.deb'))).status).toBe(201)
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    let res = await call('/api/v1/packages/to.define.dockpages/assets', {
      method: 'POST',
      headers: { ...ADMIN, 'Content-Type': 'image/png' },
      body: png,
    })
    expect(res.status).toBe(201)
    const { key } = await res.json<{ key: string }>()
    expect(key).toMatch(/^assets\/to\.define\.dockpages\/[0-9a-f]{12}\.png$/)

    res = await call('/api/v1/packages/to.define.dockpages/meta', {
      method: 'PATCH',
      headers: { ...ADMIN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ icon: key, screenshots: [key], testedOn: 'iOS 17.3' }),
    })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).toContain(`Icon: ${BASE}/${key}\n`)

    // The tested-on version is its own table row, right after Author
    const views = JSON.parse(await text('/depictions/to.define.dockpages.json')).tabs[0].views
    expect(views[0].markdown).toBe('Paged, swipeable dock with 8 icons (2 pages x 4).')
    const rows = views.filter((v: { class: string }) => v.class === 'DepictionTableTextView')
    expect(rows.map((r: { title: string; text: string }) => [r.title, r.text])).toEqual([
      ['Version', '0.1.0'],
      ['Author', 'Sion'],
      ['Tested on', 'iOS 17.3'],
    ])

    // Unknown fields are rejected
    res = await call('/api/v1/packages/to.define.dockpages/meta', {
      method: 'PATCH',
      headers: { ...ADMIN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ bogus: 1 }),
    })
    expect(res.status).toBe(400)
  })
})

describe('GitHub OIDC', () => {
  let privateJwk: JsonWebKey & { kid: string }

  beforeAll(async () => {
    const pair = (await crypto.subtle.generateKey(
      { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
      true,
      ['sign', 'verify'],
    )) as CryptoKeyPair
    privateJwk = { ...((await crypto.subtle.exportKey('jwk', pair.privateKey)) as JsonWebKey), kid: 'test-key' }
    const publicJwk = { ...((await crypto.subtle.exportKey('jwk', pair.publicKey)) as JsonWebKey), kid: 'test-key', alg: 'RS256', use: 'sig' }

    // Intercept the Worker's requests for GitHub's JWKS
    const realFetch = globalThis.fetch
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = input instanceof Request ? input.url : String(input)
      if (url === `${GITHUB_ISSUER}/.well-known/jwks`) return Response.json({ keys: [publicJwk] })
      return realFetch(input, init)
    })
  })

  afterEach(() => vi.clearAllMocks())

  async function oidc(claims: Record<string, unknown> = {}) {
    const now = Math.floor(Date.now() / 1000)
    const token = await Jwt.sign(
      {
        iss: GITHUB_ISSUER,
        aud: 'apt.define.to',
        repository: 'example/define-tweaks',
        ref: 'refs/tags/dockpages@0.1.0',
        iat: now,
        nbf: now,
        exp: now + 300,
        ...claims,
      },
      privateJwk,
      'RS256',
    )
    return { Authorization: `Bearer ${token}` }
  }

  it('a tag-triggered workflow can publish but not perform admin actions', async () => {
    const res = await put(fixture('dockpages-roothide.deb'), '', await oidc())
    expect(res.status).toBe(201)
    const deleted = await call('/api/v1/packages/to.define.dockpages/0.1.0', { method: 'DELETE', headers: await oidc() })
    expect(deleted.status).toBe(403)
    // force also needs admin
    expect((await put(fixture('dockpages-roothide.deb'), '?force=1', await oidc())).status).toBe(403)
  })

  it('checks aud / repository / ref / expiry', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb, '', await oidc({ aud: 'someone-else' }))).status).toBe(401)
    expect((await put(deb, '', await oidc({ repository: 'evil/fork' }))).status).toBe(403)
    expect((await put(deb, '', await oidc({ ref: 'refs/heads/main' }))).status).toBe(403)
    const past = Math.floor(Date.now() / 1000) - 3600
    expect((await put(deb, '', await oidc({ iat: past - 300, nbf: past - 300, exp: past }))).status).toBe(401)
  })
})

describe('serving repo files', () => {
  it('supports HEAD, Range, ETag and immutable cache headers', async () => {
    const deb = fixture('dockpages-roothide.deb')
    const { url } = await (await put(deb)).json<{ url: string }>()
    const path = new URL(url).pathname

    const full = await call(path)
    expect(full.status).toBe(200)
    expect(full.headers.get('Cache-Control')).toBe('public, max-age=31536000, immutable')
    expect(full.headers.get('Content-Type')).toBe('application/vnd.debian.binary-package')
    const etag = full.headers.get('ETag')!
    await full.arrayBuffer()

    const partial = await call(path, { headers: { Range: 'bytes=0-7' } })
    expect(partial.status).toBe(206)
    expect(partial.headers.get('Content-Range')).toBe(`bytes 0-7/${deb.byteLength}`)
    expect(new TextDecoder().decode(await partial.arrayBuffer())).toBe('!<arch>\n')

    const notModified = await call('/Packages', { headers: { 'If-None-Match': (await call('/Packages')).headers.get('ETag')! } })
    expect(notModified.status).toBe(304)
    expect(etag).toBeTruthy()

    const head = await call('/Release', { method: 'HEAD' })
    expect(head.status).toBe(200)
    expect(head.headers.get('Cache-Control')).toBe('public, max-age=60, must-revalidate')
    expect(await head.text()).toBe('')

    expect((await call('/nope')).status).toBe(404)
    expect((await call('/Packages', { method: 'POST' })).status).toBe(405)
  })
})
