import { createMiddleware } from 'hono/factory'
import type { HonoJsonWebKey } from 'hono/utils/jwt/jws'
import { Jwt } from 'hono/utils/jwt'
import type { Env } from '../env'
import { problem } from './errors'

// Authentication:
//   1. ADMIN_TOKEN (manual publishing and admin from a local machine) → admin, which includes publish
//   2. GitHub Actions OIDC (automated publishing from CI) → publish
// To support more tokens later, add another branch to authenticate

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
    if (!actor.scopes.includes(scope)) throw problem(403, 'forbidden', `Requires the ${scope} scope`)
    c.set('actor', actor)
    await next()
  })
}

export async function authenticate(header: string | undefined, env: Env): Promise<Actor> {
  const token = header?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()
  if (!token) throw problem(401, 'unauthorized', 'Missing Authorization: Bearer <token>')

  if (env.ADMIN_TOKEN && (await safeEqual(token, env.ADMIN_TOKEN))) {
    return { kind: 'admin', id: 'admin', scopes: ['publish', 'admin'] }
  }
  if (token.split('.').length === 3) return verifyGithubOidc(token, env)
  throw problem(401, 'unauthorized', 'Invalid token')
}

async function verifyGithubOidc(token: string, env: Env): Promise<Actor> {
  let payload: Record<string, unknown>
  try {
    payload = await verifyJwt(token, env, false)
  } catch {
    try {
      // GitHub may have rotated its signing keys; force a JWKS refresh and retry once
      payload = await verifyJwt(token, env, true)
    } catch (err) {
      throw problem(401, 'unauthorized', `OIDC token verification failed: ${(err as Error).message}`)
    }
  }

  const repository = String(payload.repository ?? '')
  const ref = String(payload.ref ?? '')
  const allowed = env.OIDC_REPOS.split(',').map((r) => r.trim()).filter(Boolean)
  if (!allowed.includes(repository)) throw problem(403, 'forbidden', `Repository ${repository || '(unknown)'} is not in OIDC_REPOS`)
  if (!ref.startsWith('refs/tags/')) throw problem(403, 'forbidden', `Only tag-triggered workflows may publish (ref: ${ref})`)

  return { kind: 'oidc', id: `github:${repository}@${ref.slice('refs/tags/'.length)}`, scopes: ['publish'] }
}

async function verifyJwt(token: string, env: Env, refresh: boolean): Promise<Record<string, unknown>> {
  return Jwt.verifyWithJwks(token, {
    keys: await githubJwks(refresh),
    allowedAlgorithms: ['RS256'],
    verification: { iss: GITHUB_ISSUER, aud: env.OIDC_AUDIENCE },
  })
}

// JWKS is cached in isolate memory
let jwksCache: { keys: HonoJsonWebKey[]; fetchedAt: number } | undefined

async function githubJwks(refresh: boolean): Promise<HonoJsonWebKey[]> {
  if (!refresh && jwksCache && Date.now() - jwksCache.fetchedAt < JWKS_TTL) return jwksCache.keys
  const res = await fetch(JWKS_URL)
  if (!res.ok) throw new Error(`Failed to fetch GitHub JWKS: HTTP ${res.status}`)
  const { keys } = (await res.json()) as { keys: HonoJsonWebKey[] }
  jwksCache = { keys, fetchedAt: Date.now() }
  return keys
}

// Hash both with SHA-256 first so the lengths match, then compare in constant time
async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder()
  const [ha, hb] = await Promise.all([crypto.subtle.digest('SHA-256', enc.encode(a)), crypto.subtle.digest('SHA-256', enc.encode(b))])
  return crypto.subtle.timingSafeEqual(ha, hb)
}
