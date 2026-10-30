import type { Control } from './deb'
import type { RepoIndex } from './index/repo-index'

export interface Env {
  BUCKET: R2Bucket
  REPO_INDEX: DurableObjectNamespace<RepoIndex>
  ASSETS?: Fetcher

  PUBLIC_URL: string
  REPO_LABEL: string
  REPO_DESCRIPTION: string
  OIDC_AUDIENCE: string
  // 允许 OIDC 发布的 GitHub 仓库，逗号分隔，如 "owner/define-tweaks"
  OIDC_REPOS: string
  MAX_DEB_SIZE: string
  ADMIN_TOKEN: string
}

// 一个已发布的 deb（某个包的某个版本、某个架构）
export interface PackageRecord {
  package: string
  version: string
  arch: string
  // R2 key，同时也是 Packages 里的 Filename
  filename: string
  size: number
  md5: string
  sha1: string
  sha256: string
  control: Control
  changelog: string | null
  yanked: boolean
  publishedAt: number
  actor: string
}

// 包在源上的展示信息，与具体版本无关
export interface PackageMeta {
  package: string
  name?: string
  icon?: string
  header?: string
  screenshots?: string[]
  minIos?: string
  maxIos?: string
  tags?: string[]
  sourceUrl?: string
  updatedAt?: number
}

export interface RepoConfig {
  publicUrl: string
  label: string
  description: string
}

export function repoConfig(env: Env): RepoConfig {
  return {
    publicUrl: env.PUBLIC_URL.replace(/\/$/, ''),
    label: env.REPO_LABEL,
    description: env.REPO_DESCRIPTION,
  }
}

// 让 `cloudflare:workers` 的 env 与测试里的 env 也带上这些绑定的类型
type DepotEnv = Env
declare global {
  namespace Cloudflare {
    interface Env extends DepotEnv {}
  }
}
