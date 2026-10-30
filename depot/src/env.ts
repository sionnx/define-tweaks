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
  // GitHub repositories allowed to publish via OIDC, comma-separated, e.g. "owner/define-tweaks"
  OIDC_REPOS: string
  MAX_DEB_SIZE: string
  ADMIN_TOKEN: string
}

// One published deb (a single package, version and architecture)
export interface PackageRecord {
  package: string
  version: string
  arch: string
  // R2 key, also used as Filename in Packages
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

// How a package is presented on the repo, independent of any version
export interface PackageMeta {
  package: string
  name?: string
  icon?: string
  header?: string
  screenshots?: string[]
  minIos?: string
  maxIos?: string
  // Environment the package was tested on, e.g. "iOS 17.3", shown as a row in the depiction
  testedOn?: string
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

// Give the env from `cloudflare:workers` (and in tests) these binding types too
type DepotEnv = Env
declare global {
  namespace Cloudflare {
    interface Env extends DepotEnv {}
  }
}
