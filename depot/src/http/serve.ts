import type { Env } from '../env'

// Repo file reads: served straight from R2, with HEAD, ETag/304 and Range/206 support.
// Static pages (landing page, CydiaIcon.png, …) are served by Workers Static Assets before reaching the Worker

const CONTENT_TYPES: Record<string, string> = {
  deb: 'application/vnd.debian.binary-package',
  gz: 'application/gzip',
  json: 'application/json; charset=utf-8',
  html: 'text/html; charset=utf-8',
  png: 'image/png',
  jpg: 'image/jpeg',
  webp: 'image/webp',
  gif: 'image/gif',
}

export function cacheControl(key: string): string {
  // File names contain a version or a content hash, so they never change
  if (key.startsWith('pool/') || key.startsWith('assets/')) return 'public, max-age=31536000, immutable'
  if (key.startsWith('depictions/')) return 'public, max-age=300'
  return 'public, max-age=60, must-revalidate'
}

export async function serve(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET, HEAD' } })
  }

  const key = decodeURIComponent(new URL(req.url).pathname.slice(1))
  if (!key || key.endsWith('/') || key.split('/').includes('..')) return notFound()

  // Immutable files use the edge cache; index files are always read from R2 so releases show up immediately
  const cacheable = req.method === 'GET' && !req.headers.has('Range') && cacheControl(key).includes('immutable')
  const cache = caches.default
  if (cacheable) {
    const hit = await cache.match(req)
    if (hit) return hit
  }

  const object = await env.BUCKET.get(key, { onlyIf: req.headers, range: req.headers })
  if (!object) return notFound()

  const headers = new Headers()
  object.writeHttpMetadata(headers)
  if (!headers.has('Content-Type')) {
    headers.set('Content-Type', CONTENT_TYPES[key.split('.').pop() ?? ''] ?? (isIndex(key) ? 'text/plain; charset=utf-8' : 'application/octet-stream'))
  }
  headers.set('ETag', object.httpEtag)
  headers.set('Last-Modified', object.uploaded.toUTCString())
  headers.set('Cache-Control', cacheControl(key))
  headers.set('Accept-Ranges', 'bytes')
  headers.set('Access-Control-Allow-Origin', '*')

  // Conditional request not satisfied: 304 for If-None-Match / If-Modified-Since, otherwise an If-Match style failure → 412
  if (!('body' in object)) {
    const notModified = req.headers.has('If-None-Match') || req.headers.has('If-Modified-Since')
    return new Response(null, { status: notModified ? 304 : 412, headers })
  }

  let status = 200
  const range = object.range as { offset?: number; length?: number; suffix?: number } | undefined
  if (req.headers.has('Range') && range) {
    const offset = range.suffix !== undefined ? object.size - range.suffix : (range.offset ?? 0)
    const length = range.suffix ?? range.length ?? object.size - offset
    headers.set('Content-Range', `bytes ${offset}-${offset + length - 1}/${object.size}`)
    headers.set('Content-Length', String(length))
    status = 206
  } else {
    headers.set('Content-Length', String(object.size))
  }

  const res = new Response(req.method === 'HEAD' ? null : object.body, { status, headers })
  if (cacheable && status === 200) ctx.waitUntil(cache.put(req, res.clone()))
  return res
}

function isIndex(key: string): boolean {
  return key === 'Packages' || key === 'Release' || key.startsWith('snapshots/')
}

function notFound(): Response {
  return new Response('Not Found', { status: 404, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })
}
