#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/rollback-webapps.sh --app <name> [--release <id>] [--env /etc/mnscloud/webapps/webapps.env]
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
APP=""
RELEASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$APP" ]] || die "--app is required"
require_root
acquire_webapps_lock
load_runtime_env
load_app_env "$APP"

active="$(current_app_release || true)"
if [[ -z "$RELEASE" ]]; then
  # Previous release = newest installed release directory other than the active one.
  RELEASE="$(find "$APP_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' \
    -printf '%T@ %f\n' | sort -rn | awk -v active="$active" '$2 != active { print $2; exit }')"
  [[ -n "$RELEASE" ]] || die "no previous release available for ${APP_NAME}"
fi
[[ "$RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid release id: ${RELEASE}"

target="${APP_RELEASES_DIR}/${RELEASE}"
[[ -f "${target}/index.html" ]] || die "release not found: ${target}"
activate_app_release "$target"
log "${APP_NAME} rolled back from ${active:-none} to ${RELEASE}"
if [[ "$APP_SOURCE" == "release" && "$APP_REF" == "latest" ]] && is_true "$WEBAPPS_AUTO_SYNC"; then
  log "WARNING: WEBAPPS_AUTO_SYNC=true and APP_REF=latest will move ${APP_NAME} forward again;" \
    "pin APP_REF=${RELEASE} in ${WEBAPPS_APPS_DIR}/${APP_NAME}.env to keep the rollback"
fi
