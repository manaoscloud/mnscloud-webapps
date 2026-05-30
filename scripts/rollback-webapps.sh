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
load_runtime_env
load_app_env "$APP"

if [[ -z "$RELEASE" ]]; then
  mapfile -t releases < <(find "$APP_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  [[ "${#releases[@]}" -ge 2 ]] || die "no previous release available for ${APP_NAME}"
  RELEASE="${releases[1]}"
fi

target="${APP_RELEASES_DIR}/${RELEASE}"
[[ -d "$target" ]] || die "release not found: ${target}"
ln -sfn "$target" "$APP_CURRENT_LINK"
render_app_nginx "$APP_NAME"
render_runtime_nginx
webapps_nginx -t
systemctl reload mnscloud-webapps.service 2>/dev/null || systemctl restart mnscloud-webapps.service
log "${APP_NAME} rolled back to ${RELEASE}"
