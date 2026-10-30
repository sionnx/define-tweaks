import { env } from 'cloudflare:workers'

export const ADMIN = { Authorization: 'Bearer test-admin-token' }

export function fixture(name: string): Uint8Array {
  const b64 = env.FIXTURES[name]
  if (!b64) throw new Error(`No fixture named ${name}`)
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
}

export async function sha256(bytes: Uint8Array | ArrayBuffer): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map((b) => b.toString(16).padStart(2, '0')).join('')
}
