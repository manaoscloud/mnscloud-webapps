#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/update-webapps.sh [--app <name>] [--ref <git-ref>] [--env /etc/mnscloud/webapps/webapps.env]
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
APP=""
REF_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --ref) REF_ARGS=(--ref "${2:-}"); shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
load_runtime_env

if [[ -n "$APP" ]]; then
  "${SCRIPT_DIR}/build-app.sh" --env "$ENV_FILE" --app "$APP" "${REF_ARGS[@]}"
else
  mapfile -t apps < <(enabled_apps)
  [[ "${#apps[@]}" -gt 0 ]] || die "WEBAPPS_ENABLED_APPS is empty and --app was not supplied"
  for app in "${apps[@]}"; do
    "${SCRIPT_DIR}/build-app.sh" --env "$ENV_FILE" --app "$app" "${REF_ARGS[@]}"
  done
fi
