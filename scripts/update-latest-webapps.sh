#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="/etc/mnscloud/webapps/webapps.env"
CHANNEL="stable"
APP=""
DEFAULT_API_BASE="https://dev.publichost.cloud/api/v1"
API_BASE="${MNSCLOUD_RELEASE_API_BASE_URL:-${MNSCLOUD_API_BASE_URL:-${API_BASE_URL:-$DEFAULT_API_BASE}}}"
PRINT_COMMAND=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/update-latest-webapps.sh [--env /etc/mnscloud/webapps/webapps.env] [--app <name>] [--api-base https://dev.publichost.cloud/api/v1] [--channel stable] [--print-command]

Resolves the latest approved mnscloud-webapps runtime release automatically, then applies it.
If the release registry does not expose this product yet, the helper falls back to the latest
semver Git tag from origin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    --api-base) API_BASE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --print-command) PRINT_COMMAND=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[mnscloud-webapps] ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

resolve_ref() {
  API_BASE="${API_BASE:-$DEFAULT_API_BASE}"
  API_BASE="${API_BASE%/}"
  [[ "$API_BASE" == */api/v1 ]] || API_BASE="${API_BASE}/api/v1"
  local ref
  ref="$(
    MNSCLOUD_RELEASE_URL="${API_BASE}/runtime/releases/latest?product=mnscloud-webapps&channel=${CHANNEL}" python3 <<'PY' 2>/dev/null || true
import json
import os
import urllib.request
with urllib.request.urlopen(os.environ["MNSCLOUD_RELEASE_URL"], timeout=10) as response:
    data = json.loads(response.read().decode("utf-8")).get("data") or {}
print(data.get("ref") or "")
PY
  )"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  git -C "$REPO_ROOT" fetch --tags --prune origin
  git -C "$REPO_ROOT" tag -l 'v*' --sort=-v:refname | head -n1
}

RELEASE_REF="$(resolve_ref)"
[[ -n "$RELEASE_REF" ]] || { printf '[mnscloud-webapps] ERROR: no release tag found\n' >&2; exit 1; }
printf '[mnscloud-webapps] latest runtime release: %s\n' "$RELEASE_REF"

APP_ARGS=()
[[ -n "$APP" ]] && APP_ARGS=(--app "$APP")

if [[ "$PRINT_COMMAND" == "1" ]]; then
  cat <<EOF
cd $REPO_ROOT
sudo ./scripts/update-latest-webapps.sh --env '$ENV_FILE'${APP:+ --app '$APP'}
EOF
  exit 0
fi

git -C "$REPO_ROOT" fetch --tags --prune origin
git -C "$REPO_ROOT" -c advice.detachedHead=false checkout "$RELEASE_REF"
"$REPO_ROOT/scripts/update-webapps.sh" --env "$ENV_FILE" "${APP_ARGS[@]}"
