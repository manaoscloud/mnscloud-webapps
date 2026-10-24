#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/site-remove.sh --site <32-hex> [--env /etc/mnscloud/webapps/webapps.env]

Stops serving every host of one hosted website and deletes its releases. Removing a site that is not
installed succeeds. Run by the Agent job website.site (remove).
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
SITE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$SITE" ]] || { usage; die "--site is required"; }

require_root
acquire_webapps_lock
load_runtime_env
remove_site "$SITE"
log "website ${SITE} removed"
