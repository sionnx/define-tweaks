import type { Env } from './env'
import { api } from './http/api'
import { serve } from './http/serve'

export default {
  fetch(req, env, ctx) {
    // The API goes through Hono; everything else is repo file reads, the hottest path, which skips the framework
    return new URL(req.url).pathname.startsWith('/api/') ? api.fetch(req, env, ctx) : serve(req, env, ctx)
  },
} satisfies ExportedHandler<Env>

export { RepoIndex } from './index/repo-index'

// Lets a CLI use hono/client for type-safe calls
export type AppType = typeof api
export type { PublishResponse } from './http/api'
export type { PackageMeta, PackageRecord } from './env'
