#!/usr/bin/env bash
# Publish a deb to depot (apt.define.to).
#
# Usage: scripts/publish.sh <deb> [changelog]
#
# Environment:
#   DEPOT_TOKEN  Required. ADMIN_TOKEN locally, a GitHub OIDC token in CI
#   DEPOT_URL    Optional, defaults to https://apt.define.to
#
# Local example:
#   DEPOT_TOKEN=$(security find-generic-password -s apt.define.to -a ADMIN_TOKEN -w) \
#     scripts/publish.sh tweaks/DockReel/packages/to.define.dockreel_0.1.0_iphoneos-arm64e.deb "First release"
set -euo pipefail

deb=${1:?Usage: $0 <deb> [changelog]}
changelog=${2:-}
url=${DEPOT_URL:-https://apt.define.to}
: "${DEPOT_TOKEN:?DEPOT_TOKEN must be set}"

[[ -f $deb ]] || { echo "File not found: $deb" >&2; exit 1; }

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# --form-string keeps curl from treating a changelog starting with @ or < as a file
status=$(curl -sS -o "$body" -w '%{http_code}' -X POST "$url/api/v1/packages" \
  -H "Authorization: Bearer $DEPOT_TOKEN" \
  -F "deb=@$deb;type=application/vnd.debian.binary-package" \
  --form-string "changelog=$changelog")

cat "$body"
echo
if (( status >= 400 )); then
  echo "Publish failed: HTTP $status" >&2
  exit 1
fi
