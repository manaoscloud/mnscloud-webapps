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

probe_host="$WEBAPPS_LISTEN_HOST"
[[ "$probe_host" == "0.0.0.0" ]] && probe_host="127.0.0.1"
base_url="http://${probe_host}:${WEBAPPS_LISTEN_PORT}"

if command -v curl >/dev/null 2>&1; then
  curl -fsS "${base_url}/healthz" >/dev/null || die "health check failed"
fi

failed=0
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  load_app_env "$app"
  release="$(current_app_release || true)"
  if [[ -z "$release" || ! -f "${APP_CURRENT_LINK}/index.html" ]]; then
    log "FAIL ${app}: no active release (run scripts/update-webapps.sh --app ${app})"
    failed=1
    continue
  fi
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$APP_SERVER_NAME" ]]; then
      host="${APP_SERVER_NAME%% *}"
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "${base_url}/" || true)"
      where="${host}/"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' "${base_url}${APP_BASE_PATH}" || true)"
      where="$APP_BASE_PATH"
    fi
    if [[ "$code" != "200" ]]; then
      log "FAIL ${app}: ${where} returned HTTP ${code}"
      failed=1
      continue
    fi
  fi
  log "OK ${app}: release ${release} (${APP_SOURCE}) at ${where:-$APP_BASE_PATH}"
done < <(enabled_apps)

[[ "$failed" == "0" ]] || die "validation failed"
log "validation completed"
