import { readdirSync, readFileSync } from 'node:fs'
import { cloudflareTest } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'

// Tests run inside the Workers runtime (they need MD5 in crypto.subtle, R2 and DO).
// The runtime has no filesystem, so the deb fixtures are injected as base64 bindings
const dir = new URL('./test/fixtures/', import.meta.url)
const fixtures = Object.fromEntries(
  readdirSync(dir)
    .filter((f) => f.endsWith('.deb'))
    .map((f) => [f, readFileSync(new URL(f, dir)).toString('base64')]),
)

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.jsonc' },
      miniflare: {
        bindings: {
          ADMIN_TOKEN: 'test-admin-token',
          OIDC_REPOS: 'example/define-tweaks',
          FIXTURES: fixtures,
        },
      },
    }),
  ],
})
