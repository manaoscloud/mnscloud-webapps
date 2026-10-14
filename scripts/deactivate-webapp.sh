#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF2
Usage: scripts/deactivate-webapp.sh --app <name> [--env /etc/mnscloud/webapps/webapps.env]

Stops serving one app (nginx locations and current release link) and reloads the runtime. Keeps its
releases, state and apps.d env file. Remove the app from WEBAPPS_ENABLED_APPS as well, or the next
sync installs it again; the Agent reconcile resource webapps.apps does both.
EOF2
}

ENV_FILE="$DEFAULT_ENV_FILE"
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$APP" ]] || { usage; die "--app is required"; }

require_root
acquire_webapps_lock
load_runtime_env
deactivate_app "$APP"
log "deactivated ${APP}"
