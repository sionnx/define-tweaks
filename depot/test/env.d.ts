declare namespace Cloudflare {
  interface Env {
    // 测试用 deb 样本：文件名 → base64
    FIXTURES: Record<string, string>
  }
  // 让 `exports.default` 带上主模块的类型
  interface GlobalProps {
    mainModule: typeof import('../src/index')
  }
}
