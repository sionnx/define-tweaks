import { zValidator } from '@hono/zod-validator'
import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { z } from 'zod'
import {
  ControlValidationError,
  DebFormatError,
  type InspectedDeb,
  inspectDeb,
  type PackageIdentity,
  UnsupportedCompressionError,
  validateControl,
} from '../deb'
import { type Env, type PackageRecord, repoConfig } from '../env'
import type { Result } from '../index/repo-index'
import { type Actor, type AppEnv, requireScope } from './auth'
import { problem, problemResponse } from './errors'

const DEB_TYPE = 'application/vnd.debian.binary-package'
const ASSET_MAX = 10 * 1024 * 1024
const ASSET_TYPES: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif' }

const flag = z
  .enum(['0', '1', 'true', 'false'])
  .optional()
  .transform((v) => v === '1' || v === 'true')

const publishQuery = z.object({
  changelog: z.string().max(10_000).optional(),
  force: flag,
  allowDebug: flag,
})

const metaPatch = z
  .object({
    name: z.string().min(1).max(100),
    icon: z.string().max(500),
    header: z.string().max(500),
    screenshots: z.array(z.string().max(500)).max(20),
    minIos: z.string().regex(/^\d+(\.\d+){0,2}$/),
    maxIos: z.string().regex(/^\d+(\.\d+){0,2}$/),
    testedOn: z.string().min(1).max(60),
    tags: z.array(z.string().max(40)).max(20),
    sourceUrl: z.url(),
  })
  .partial()
  .strict()

// Validation failures are always reported as problem+json
const validate = <T extends z.ZodType, K extends 'query' | 'json' | 'param'>(target: K, schema: T) =>
  zValidator(target, schema, (result) => {
    if (!result.success) {
      throw problem(400, 'invalid-request', result.error.issues.map((i) => `${i.path.join('.') || target}: ${i.message}`).join('; '))
    }
  })

export const api = new Hono<AppEnv>()
  .basePath('/api/v1')

  // Upload a raw deb (the request body is the file)
  .put('/packages', requireScope('publish'), validate('query', publishQuery), async (c) => {
    const query = c.req.valid('query')
    const bytes = await readBody(c.req.raw, maxDebSize(c.env), 'deb')
    const result = await publishDeb(c.env, c.var.actor, bytes, query)
    return c.json(result, result.created ? 201 : 200)
  })

  // Multipart upload: the deb file plus an optional changelog and meta (JSON)
  .post('/packages', requireScope('publish'), validate('query', publishQuery), async (c) => {
    const query = c.req.valid('query')
    const lengthLimit = maxDebSize(c.env) + 1024 * 1024
    if (Number(c.req.header('Content-Length') ?? 0) > lengthLimit) throw tooLarge(lengthLimit)

    const form = await c.req.formData()
    const file = form.get('deb')
    if (!(file instanceof File)) throw problem(400, 'invalid-request', 'Missing deb file field')
    if (file.size > maxDebSize(c.env)) throw tooLarge(maxDebSize(c.env))

    let meta: z.infer<typeof metaPatch> | undefined
    const rawMeta = form.get('meta')
    if (typeof rawMeta === 'string' && rawMeta.trim()) {
      const parsed = metaPatch.safeParse(safeJson(rawMeta))
      if (!parsed.success) throw problem(400, 'invalid-request', `Invalid meta: ${parsed.error.message}`)
      meta = parsed.data
    }
    const changelog = form.get('changelog')
    const result = await publishDeb(c.env, c.var.actor, new Uint8Array(await file.arrayBuffer()), {
      ...query,
      changelog: typeof changelog === 'string' && changelog ? changelog : query.changelog,
    })
    if (meta && Object.keys(meta).length) unwrap(await repo(c.env).setMeta(result.package, meta, c.var.actor.id))
    return c.json(result, result.created ? 201 : 200)
  })

  .get('/packages', async (c) => c.json(await repo(c.env).listPackages()))

  .get('/packages/:pkg', async (c) => c.json(unwrap(await repo(c.env).getPackage(c.req.param('pkg')))))

  .patch('/packages/:pkg/meta', requireScope('publish'), validate('json', metaPatch), async (c) => {
    return c.json(unwrap(await repo(c.env).setMeta(c.req.param('pkg'), c.req.valid('json'), c.var.actor.id)))
  })

  // Upload an icon / screenshot, stored content-addressed; the returned key can go straight into meta
  .post('/packages/:pkg/assets', requireScope('publish'), async (c) => {
    const pkg = c.req.param('pkg')
    unwrap(await repo(c.env).getPackage(pkg))
    const type = (c.req.header('Content-Type') ?? '').split(';')[0]!.trim()
    const ext = ASSET_TYPES[type]
    if (!ext) throw problem(415, 'unsupported-media-type', `Only ${Object.keys(ASSET_TYPES).join(', ')} are supported`)

    const bytes = await readBody(c.req.raw, ASSET_MAX, 'asset')
    const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))]
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')
    const key = `assets/${pkg}/${hash.slice(0, 12)}.${ext}`
    await c.env.BUCKET.put(key, bytes, { httpMetadata: { contentType: type } })
    return c.json({ key, url: `${repoConfig(c.env).publicUrl}/${key}` }, 201)
  })

  .delete(
    '/packages/:pkg/:version',
    requireScope('admin'),
    validate('query', z.object({ arch: z.string().optional(), purge: flag })),
    async (c) => {
      const { arch, purge } = c.req.valid('query')
      const result = await repo(c.env).yank(c.req.param('pkg'), c.req.param('version'), { arch, purge, actor: c.var.actor.id })
      return c.json(unwrap(result))
    },
  )

  .post('/index/rebuild', requireScope('admin'), async (c) => c.json(await repo(c.env).rebuildManually(c.var.actor.id)))

  .get('/index/snapshots', requireScope('admin'), async (c) => c.json(await repo(c.env).listSnapshots()))

  .post(
    '/index/rollback/:gen',
    requireScope('admin'),
    validate('param', z.object({ gen: z.coerce.number().int().positive() })),
    async (c) => c.json(unwrap(await repo(c.env).rollback(c.req.valid('param').gen, c.var.actor.id))),
  )

api.notFound(() => problemResponse(404, 'not-found', 'No such endpoint'))
api.onError((err) => {
  if (err instanceof HTTPException) return err.getResponse()
  console.error(err)
  return problemResponse(500, 'internal', 'Internal server error')
})

export interface PublishResponse {
  gen: number
  created: boolean
  package: string
  version: string
  arch: string
  size: number
  sha256: string
  url: string
}

async function publishDeb(
  env: Env,
  actor: Actor,
  bytes: Uint8Array,
  options: { changelog?: string; force: boolean; allowDebug: boolean },
): Promise<PublishResponse> {
  if (options.force && !actor.scopes.includes('admin')) throw problem(403, 'forbidden', 'force requires the admin scope')

  let deb: InspectedDeb
  let id: PackageIdentity
  try {
    deb = await inspectDeb(bytes)
    id = validateControl(deb.control, { allowDebug: options.allowDebug })
  } catch (err) {
    if (err instanceof ControlValidationError) throw problem(422, 'invalid-control', err.message, { problems: err.problems })
    if (err instanceof UnsupportedCompressionError) throw problem(422, 'unsupported-compression', err.message)
    if (err instanceof DebFormatError) throw problem(422, 'invalid-deb', err.message)
    throw err
  }

  // Debian convention: no epoch in file names
  const fileVersion = id.version.replace(/^\d+:/, '')
  const filename = `pool/${id.package}/${id.package}_${fileVersion}_${id.arch}.deb`

  // Debs are immutable: if the file already exists, continue only when the content is identical (a retry) or with force
  const existing = await env.BUCKET.head(filename)
  if (existing && existing.customMetadata?.sha256 !== deb.sha256 && !options.force) {
    throw problem(409, 'version-exists', `${id.package} ${id.version} (${id.arch}) is already published with different content; bump the version`)
  }
  if (!existing || options.force) {
    await env.BUCKET.put(filename, bytes, {
      httpMetadata: { contentType: DEB_TYPE },
      customMetadata: { sha256: deb.sha256 },
    })
  }

  const record: PackageRecord = {
    ...id,
    filename,
    size: deb.size,
    md5: deb.md5,
    sha1: deb.sha1,
    sha256: deb.sha256,
    control: deb.control,
    changelog: options.changelog ?? null,
    yanked: false,
    publishedAt: Date.now(),
    actor: actor.id,
  }
  const { gen, created } = unwrap(await repo(env).publish(record, { force: options.force }))
  return {
    gen,
    created,
    package: id.package,
    version: id.version,
    arch: id.arch,
    size: deb.size,
    sha256: deb.sha256,
    url: `${repoConfig(env).publicUrl}/${filename}`,
  }
}

function repo(env: Env) {
  return env.REPO_INDEX.get(env.REPO_INDEX.idFromName('main'))
}

function unwrap<T>(result: Result<T>): T {
  if (result.ok) return result.value
  throw problem(result.status, result.status === 404 ? 'not-found' : 'conflict', result.detail)
}

function maxDebSize(env: Env): number {
  return Number(env.MAX_DEB_SIZE) || 64 * 1024 * 1024
}

function tooLarge(limit: number) {
  return problem(413, 'too-large', `File exceeds the ${Math.round(limit / 1024 / 1024)}MB limit`)
}

// Reject early on Content-Length, then double-check the actual length read
async function readBody(req: Request, limit: number, what: string): Promise<Uint8Array> {
  if (Number(req.headers.get('Content-Length') ?? 0) > limit) throw tooLarge(limit)
  const bytes = new Uint8Array(await req.arrayBuffer())
  if (bytes.byteLength === 0) throw problem(400, 'invalid-request', `Empty request body; expected a ${what}`)
  if (bytes.byteLength > limit) throw tooLarge(limit)
  return bytes
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}
