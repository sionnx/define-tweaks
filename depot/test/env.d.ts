declare namespace Cloudflare {
  interface Env {
    // Test fixture debs: file name → base64
    FIXTURES: Record<string, string>
  }
  // Type `exports.default` as the main module
  interface GlobalProps {
    mainModule: typeof import('../src/index')
  }
}
