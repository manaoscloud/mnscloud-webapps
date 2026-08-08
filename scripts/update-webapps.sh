#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/update-webapps.sh [--app <name>] [--ref <runtime-git-ref>] [--app-ref <app-git-ref>] [--env /etc/mnscloud/webapps/webapps.env]
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
APP=""
RUNTIME_REF=""
APP_REF_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --ref) RUNTIME_REF="${2:-}"; shift 2 ;;
    --app-ref) APP_REF_ARGS=(--ref "${2:-}"); shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
if [[ -n "$RUNTIME_REF" ]]; then
  ensure_git
  git -C "$ROOT_DIR" fetch --tags --prune origin
  git -C "$ROOT_DIR" -c advice.detachedHead=false checkout "$RUNTIME_REF"
fi
load_runtime_env

if [[ -n "$APP" ]]; then
  "${SCRIPT_DIR}/build-app.sh" --env "$ENV_FILE" --app "$APP" "${APP_REF_ARGS[@]}"
else
  mapfile -t apps < <(enabled_apps)
  [[ "${#apps[@]}" -gt 0 ]] || die "WEBAPPS_ENABLED_APPS is empty and --app was not supplied"
  for app in "${apps[@]}"; do
    "${SCRIPT_DIR}/build-app.sh" --env "$ENV_FILE" --app "$app" "${APP_REF_ARGS[@]}"
  done
fi
