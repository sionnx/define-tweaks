import { HTTPException } from 'hono/http-exception'
import type { ContentfulStatusCode } from 'hono/utils/http-status'

// RFC 9457 problem+json 错误
export interface Problem {
  type: string
  title: string
  status: number
  detail?: string
  [extra: string]: unknown
}

const TITLES: Record<number, string> = {
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  409: 'Conflict',
  413: 'Payload Too Large',
  415: 'Unsupported Media Type',
  422: 'Unprocessable Content',
  500: 'Internal Server Error',
}

export function problemResponse(status: ContentfulStatusCode, slug: string, detail?: string, extra: object = {}): Response {
  const body: Problem = {
    type: `https://apt.define.to/errors/${slug}`,
    title: TITLES[status] ?? 'Error',
    status,
    ...(detail ? { detail } : {}),
    ...extra,
  }
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/problem+json; charset=utf-8', 'Cache-Control': 'no-store' },
  })
}

// 在路由里直接 throw，由 app.onError 统一输出
export function problem(status: ContentfulStatusCode, slug: string, detail?: string, extra?: object): HTTPException {
  return new HTTPException(status, { res: problemResponse(status, slug, detail, extra) })
}
