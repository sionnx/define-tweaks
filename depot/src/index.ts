import type { Env } from './env'
import { api } from './http/api'
import { serve } from './http/serve'

export default {
  fetch(req, env, ctx) {
    // API 走 Hono；其余全部是源文件读取，这是最热的路径，不经过框架
    return new URL(req.url).pathname.startsWith('/api/') ? api.fetch(req, env, ctx) : serve(req, env, ctx)
  },
} satisfies ExportedHandler<Env>

export { RepoIndex } from './index/repo-index'

// 供 cli 使用 hono/client 获得类型安全的调用
export type AppType = typeof api
export type { PublishResponse } from './http/api'
export type { PackageMeta, PackageRecord } from './env'
