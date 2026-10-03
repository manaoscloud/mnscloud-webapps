#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if ! parse_env_arg "$@"; then
  cat <<EOF
Usage: scripts/sync-webapps.sh [--env /etc/mnscloud/webapps/webapps.env]

Converges every enabled APP_SOURCE=release app to its APP_REF (a pinned tag or "latest").
Apps already at the resolved release are left untouched. APP_SOURCE=build apps are skipped;
rebuild them with scripts/update-webapps.sh. Run by mnscloud-webapps-sync.timer when
WEBAPPS_AUTO_SYNC=true.
EOF
  exit 0
fi

require_root
acquire_webapps_lock
load_runtime_env

failed=0
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  load_app_env "$app"
  if [[ "$APP_SOURCE" != "release" ]]; then
    log "skipping ${app}: APP_SOURCE=${APP_SOURCE}"
    continue
  fi
  "${SCRIPT_DIR}/build-app.sh" --env "$ENV_FILE" --app "$app" || failed=1
done < <(enabled_apps)

[[ "$failed" == "0" ]] || die "one or more apps failed to sync"
log "sync completed"
