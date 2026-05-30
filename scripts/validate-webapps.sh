#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if ! parse_env_arg "$@"; then
  cat <<EOF
Usage: scripts/validate-webapps.sh [--env /etc/mnscloud/webapps/webapps.env]
EOF
  exit 0
fi

load_runtime_env
render_runtime_nginx
webapps_nginx -t

if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet mnscloud-webapps.service || die "mnscloud-webapps.service is not active"
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://${WEBAPPS_LISTEN_HOST}:${WEBAPPS_LISTEN_PORT}/healthz" >/dev/null \
    || die "health check failed"
fi

log "validation completed"
