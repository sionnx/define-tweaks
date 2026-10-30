import { reset } from 'cloudflare:test'
import { env, exports } from 'cloudflare:workers'
import { Jwt } from 'hono/utils/jwt'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { gunzip } from '../src/deb/decompress'
import { GITHUB_ISSUER } from '../src/http/auth'
import { ADMIN, fixture, sha256 } from './helpers'

const BASE = 'https://apt.define.to'

// 每个用例从空的 R2 和 DO 开始
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

describe('发布流程', () => {
  it('发布 → 索引 → 描述页 → 元数据 → 下架 → 回滚', async () => {
    const deb = fixture('dockpages-roothide.deb')
    const debHash = await sha256(deb)

    // 首次发布
    let res = await put(deb, '?changelog=' + encodeURIComponent('First release'))
    expect(res.status).toBe(201)
    const published = await res.json<{ gen: number; created: boolean; url: string; sha256: string }>()
    expect(published).toMatchObject({
      gen: 1,
      created: true,
      sha256: debHash,
      url: `${BASE}/pool/to.define.dockpages/to.define.dockpages_0.1.0_iphoneos-arm64e.deb`,
    })

    // 相同文件重复上传是幂等的，不产生新快照
    res = await put(deb)
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ gen: 1, created: false })

    // Packages 条目与哈希
    const packages = await text('/Packages')
    expect(packages).toContain('Package: to.define.dockpages\n')
    expect(packages).toContain('Filename: pool/to.define.dockpages/to.define.dockpages_0.1.0_iphoneos-arm64e.deb\n')
    expect(packages).toContain(`SHA256: ${debHash}\n`)
    expect(packages).toContain(`Size: ${deb.byteLength}\n`)
    expect(packages).toContain(`SileoDepiction: ${BASE}/depictions/to.define.dockpages.json`)

    // Packages.gz 解压后与 Packages 一致；Release 里记录的哈希正确
    const gz = new Uint8Array(await (await call('/Packages.gz')).arrayBuffer())
    expect(new TextDecoder().decode(await gunzip(gz))).toBe(packages)
    const release = await text('/Release')
    const packagesBytes = new TextEncoder().encode(packages)
    expect(release).toContain(`${await sha256(packagesBytes)} ${String(packagesBytes.byteLength).padStart(8)} Packages\n`)
    expect(release).toContain(`${await sha256(gz)} ${String(gz.byteLength).padStart(8)} Packages.gz\n`)
    expect(release).toContain('Architectures: iphoneos-arm64e iphoneos-arm64 iphoneos-arm\n')

    // 描述页
    const sileo = JSON.parse(await text('/depictions/to.define.dockpages.json'))
    expect(sileo.class).toBe('DepictionTabView')
    expect(JSON.stringify(sileo)).toContain('First release')
    expect(await text('/depictions/to.define.dockpages.html')).toContain('<title>DockPages</title>')

    // multipart 发布第二个包（rootless，带 epoch），同时写入元数据
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
    // 文件名去掉 epoch
    expect(withSample).toContain('Filename: pool/com.example.sample/com.example.sample_2.0~beta1-3_iphoneos-arm64.deb\n')
    // 多行描述按 Debian 格式输出
    expect(withSample).toContain('Description: Sample rootless package\n Long description line one.\n .\n Line after blank.\n')

    // 列表接口
    const list = await (await call('/api/v1/packages')).json<{ package: string }[]>()
    expect(list.map((p) => p.package)).toEqual(['com.example.sample', 'to.define.dockpages'])

    // 下架 sample
    res = await call('/api/v1/packages/com.example.sample/1:2.0~beta1-3', { method: 'DELETE', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).not.toContain('com.example.sample')

    // 回滚到包含 sample 的快照
    const snapshots = await (await call('/api/v1/index/snapshots', { headers: ADMIN })).json<{ gen: number; entries: number }[]>()
    const target = snapshots.find((s) => s.entries === 2)!
    res = await call(`/api/v1/index/rollback/${target.gen}`, { method: 'POST', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).toContain('Package: com.example.sample\n')

    // purge 删除记录和文件
    res = await call('/api/v1/packages/com.example.sample/1:2.0~beta1-3?purge=1', { method: 'DELETE', headers: ADMIN })
    expect(res.status).toBe(200)
    expect(await env.BUCKET.head('pool/com.example.sample/com.example.sample_2.0~beta1-3_iphoneos-arm64.deb')).toBeNull()
    expect((await call('/api/v1/packages/com.example.sample')).status).toBe(404)
  })

  it('同版本不同内容返回 409，admin 可以 force 覆盖', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb)).status).toBe(201)

    // 改动 data 成员的最后一个字节：control 不变，但文件内容不同
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

  it('拒绝调试包、不支持的压缩格式和非 deb 文件', async () => {
    let res = await put(fixture('dockpages-debug.deb'))
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ type: 'https://apt.define.to/errors/invalid-control' })
    expect((await put(fixture('dockpages-debug.deb'), '?allowDebug=1')).status).toBe(201)

    res = await put(fixture('sample-xz.deb'))
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ type: 'https://apt.define.to/errors/unsupported-compression' })

    expect((await put(new TextEncoder().encode('not a deb'))).status).toBe(422)
  })

  it('认证', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb, '', {})).status).toBe(401)
    expect((await put(deb, '', { Authorization: 'Bearer wrong' })).status).toBe(401)
    expect((await call('/api/v1/index/rebuild', { method: 'POST' })).status).toBe(401)
    // 公开的只读接口不需要认证
    expect((await call('/api/v1/packages')).status).toBe(200)
  })

  it('上传图标并通过 PATCH 写入元数据', async () => {
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
      body: JSON.stringify({ icon: key, screenshots: [key] }),
    })
    expect(res.status).toBe(200)
    expect(await text('/Packages')).toContain(`Icon: ${BASE}/${key}\n`)

    // 未知字段被拒绝
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

    // 拦截 Worker 对 GitHub JWKS 的请求
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

  it('tag 触发的 workflow 可以发布，但不能做管理操作', async () => {
    const res = await put(fixture('dockpages-roothide.deb'), '', await oidc())
    expect(res.status).toBe(201)
    const deleted = await call('/api/v1/packages/to.define.dockpages/0.1.0', { method: 'DELETE', headers: await oidc() })
    expect(deleted.status).toBe(403)
    // force 也需要 admin
    expect((await put(fixture('dockpages-roothide.deb'), '?force=1', await oidc())).status).toBe(403)
  })

  it('aud / 仓库 / ref / 过期 校验', async () => {
    const deb = fixture('dockpages-roothide.deb')
    expect((await put(deb, '', await oidc({ aud: 'someone-else' }))).status).toBe(401)
    expect((await put(deb, '', await oidc({ repository: 'evil/fork' }))).status).toBe(403)
    expect((await put(deb, '', await oidc({ ref: 'refs/heads/main' }))).status).toBe(403)
    const past = Math.floor(Date.now() / 1000) - 3600
    expect((await put(deb, '', await oidc({ iat: past - 300, nbf: past - 300, exp: past }))).status).toBe(401)
  })
})

describe('源文件读取', () => {
  it('支持 HEAD、Range、ETag 和不可变缓存头', async () => {
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
