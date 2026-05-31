#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/install-webapps.sh [--env /etc/mnscloud/webapps/webapps.env]
EOF
}

if ! parse_env_arg "$@"; then
  usage
  exit 0
fi

require_root

if [[ ! -f "$ENV_FILE" ]]; then
  install -d -m 0750 "$(dirname "$ENV_FILE")"
  install -m 0640 "${ROOT_DIR}/config/webapps.env.example" "$ENV_FILE"
  log "created env file: $ENV_FILE"
fi

load_runtime_env
install_nginx_package
disable_default_nginx_service
ensure_service_user
ensure_flutter
NGINX_BIN="$(command -v nginx || true)"
[[ -n "$NGINX_BIN" ]] || die "nginx is required"

install -d -m 0755 "$WEBAPPS_ROOT" \
  "$WEBAPPS_ROOT/repos" \
  "$WEBAPPS_ROOT/releases" \
  "$WEBAPPS_ROOT/current" \
  "$WEBAPPS_ROOT/runtime/logs" \
  "$WEBAPPS_ENV_DIR/apps.d" \
  "$WEBAPPS_ENV_DIR/nginx/apps"

for example in "${ROOT_DIR}"/config/apps.d/*.env.example; do
  target="${WEBAPPS_APPS_DIR}/$(basename "${example%.example}")"
  [[ -f "$target" ]] || install -m 0640 "$example" "$target"
done

render_runtime_nginx

cat > /etc/systemd/system/mnscloud-webapps.service <<EOF
[Unit]
Description=MNSCloud private webapps static runtime
After=network.target

[Service]
Type=forking
PIDFile=${WEBAPPS_ROOT}/runtime/nginx.pid
ExecStartPre=${NGINX_BIN} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -t
ExecStart=${NGINX_BIN} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf
ExecReload=${NGINX_BIN} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -s reload
ExecStop=${NGINX_BIN} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -s quit
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${WEBAPPS_ROOT} ${WEBAPPS_ENV_DIR}

[Install]
WantedBy=multi-user.target
EOF

chown -R "$WEBAPPS_USER:$WEBAPPS_GROUP" "$WEBAPPS_ROOT"
systemctl daemon-reload
systemctl enable mnscloud-webapps.service
webapps_nginx -t
systemctl restart mnscloud-webapps.service

log "installed webapps runtime on ${WEBAPPS_LISTEN_HOST}:${WEBAPPS_LISTEN_PORT}"
