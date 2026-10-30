import { readdirSync, readFileSync } from 'node:fs'
import { cloudflareTest } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'

// 测试在 Workers 运行时里执行（需要 crypto.subtle 的 MD5、R2、DO），
// 运行时里没有文件系统，所以把 deb 样本以 base64 形式注入为绑定
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
