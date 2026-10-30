#!/usr/bin/env bash
# 把 deb 发布到 depot（apt.define.to）。
#
# 用法：scripts/publish.sh <deb> [changelog]
#
# 环境变量：
#   DEPOT_TOKEN  必填。本机用 ADMIN_TOKEN，CI 里用 GitHub OIDC token
#   DEPOT_URL    可选，默认 https://apt.define.to
#
# 本机示例：
#   DEPOT_TOKEN=$(security find-generic-password -s apt.define.to -a ADMIN_TOKEN -w) \
#     scripts/publish.sh tweaks/DockReel/packages/to.define.dockreel_0.1.0_iphoneos-arm64e.deb "First release"
set -euo pipefail

deb=${1:?用法：$0 <deb> [changelog]}
changelog=${2:-}
url=${DEPOT_URL:-https://apt.define.to}
: "${DEPOT_TOKEN:?需要设置 DEPOT_TOKEN}"

[[ -f $deb ]] || { echo "找不到文件：$deb" >&2; exit 1; }

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# --form-string 避免 changelog 以 @ 或 < 开头时被 curl 当作文件
status=$(curl -sS -o "$body" -w '%{http_code}' -X POST "$url/api/v1/packages" \
  -H "Authorization: Bearer $DEPOT_TOKEN" \
  -F "deb=@$deb;type=application/vnd.debian.binary-package" \
  --form-string "changelog=$changelog")

cat "$body"
echo
if (( status >= 400 )); then
  echo "发布失败：HTTP $status" >&2
  exit 1
fi
