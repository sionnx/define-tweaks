import { createMiddleware } from 'hono/factory'
import type { HonoJsonWebKey } from 'hono/utils/jwt/jws'
import { Jwt } from 'hono/utils/jwt'
import type { Env } from '../env'
import { problem } from './errors'

// 认证方式：
//   1. ADMIN_TOKEN（本机手动发布与管理）→ admin，包含 publish
//   2. GitHub Actions OIDC（CI 自动发布）→ publish
// 以后加多 token 时，在 authenticate 里新增一个分支即可

export type Scope = 'publish' | 'admin'

export interface Actor {
  kind: 'admin' | 'oidc'
  id: string
  scopes: Scope[]
}

export type AppEnv = { Bindings: Env; Variables: { actor: Actor } }

export const GITHUB_ISSUER = 'https://token.actions.githubusercontent.com'
const JWKS_URL = `${GITHUB_ISSUER}/.well-known/jwks`
const JWKS_TTL = 60 * 60 * 1000

export function requireScope(scope: Scope) {
  return createMiddleware<AppEnv>(async (c, next) => {
    const actor = await authenticate(c.req.header('Authorization'), c.env)
    if (!actor.scopes.includes(scope)) throw problem(403, 'forbidden', `需要 ${scope} 权限`)
    c.set('actor', actor)
    await next()
  })
}

export async function authenticate(header: string | undefined, env: Env): Promise<Actor> {
  const token = header?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()
  if (!token) throw problem(401, 'unauthorized', '缺少 Authorization: Bearer <token>')

  if (env.ADMIN_TOKEN && (await safeEqual(token, env.ADMIN_TOKEN))) {
    return { kind: 'admin', id: 'admin', scopes: ['publish', 'admin'] }
  }
  if (token.split('.').length === 3) return verifyGithubOidc(token, env)
  throw problem(401, 'unauthorized', 'token 无效')
}

async function verifyGithubOidc(token: string, env: Env): Promise<Actor> {
  let payload: Record<string, unknown>
  try {
    payload = await verifyJwt(token, env, false)
  } catch {
    try {
      // 可能是 GitHub 轮换了签名密钥，强制刷新 JWKS 再试一次
      payload = await verifyJwt(token, env, true)
    } catch (err) {
      throw problem(401, 'unauthorized', `OIDC token 校验失败：${(err as Error).message}`)
    }
  }

  const repository = String(payload.repository ?? '')
  const ref = String(payload.ref ?? '')
  const allowed = env.OIDC_REPOS.split(',').map((r) => r.trim()).filter(Boolean)
  if (!allowed.includes(repository)) throw problem(403, 'forbidden', `仓库 ${repository || '(未知)'} 不在 OIDC_REPOS 白名单中`)
  if (!ref.startsWith('refs/tags/')) throw problem(403, 'forbidden', `只允许由 tag 触发的 workflow 发布（当前 ref：${ref}）`)

  return { kind: 'oidc', id: `github:${repository}@${ref.slice('refs/tags/'.length)}`, scopes: ['publish'] }
}

async function verifyJwt(token: string, env: Env, refresh: boolean): Promise<Record<string, unknown>> {
  return Jwt.verifyWithJwks(token, {
    keys: await githubJwks(refresh),
    allowedAlgorithms: ['RS256'],
    verification: { iss: GITHUB_ISSUER, aud: env.OIDC_AUDIENCE },
  })
}

// JWKS 缓存在 isolate 内存里
let jwksCache: { keys: HonoJsonWebKey[]; fetchedAt: number } | undefined

async function githubJwks(refresh: boolean): Promise<HonoJsonWebKey[]> {
  if (!refresh && jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL) return jwksCache.keys
  const res = await fetch(JWKS_URL)
  if (!res.ok) throw new Error(`获取 GitHub JWKS 失败：HTTP ${res.status}`)
  const { keys } = (await res.json()) as { keys: HonoJsonWebKey[] }
  jwksCache = { keys, fetchedAt: Date.now() }
  return keys
}

// 先各自做 SHA-256，保证长度一致后再做常量时间比较
async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder()
  const [ha, hb] = await Promise.all([crypto.subtle.digest('SHA-256', enc.encode(a)), crypto.subtle.digest('SHA-256', enc.encode(b))])
  return crypto.subtle.timingSafeEqual(ha, hb)
}
