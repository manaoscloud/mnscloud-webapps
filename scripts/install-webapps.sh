#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AGENT_REPO_INSTALLER="/opt/mnscloud/mnscloud-agent/scripts/install-agent.sh"

usage() {
  cat <<EOF
Usage: scripts/install-webapps.sh [--env /etc/mnscloud/webapps/webapps.env]
EOF
}

AGENT_CONFIG_FILE="${AGENT_CONFIG_FILE:-/etc/mnscloud/agent/agent.conf}"

# Prints the enrolled Agent name (MonitoringAgent.MagName) from the local Agent config, if any.
existing_agent_name() {
  [[ -r "$AGENT_CONFIG_FILE" ]] || return 0
  awk '/^[[:space:]]*name[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' \
    "$AGENT_CONFIG_FILE"
}

refresh_agent_capabilities() {
  local install_label
  # Keep the enrolled Agent name; fall back to the FQDN only when the Agent has no name yet.
  # Passing the FQDN unconditionally renames Agents that were enrolled with a short name.
  install_label="$(existing_agent_name)"
  [[ -n "$install_label" ]] ||
    install_label="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'mnscloud-agent')"

  if [[ -x "${AGENT_REPO_INSTALLER}" ]]; then
    log "refreshing mnscloud-agent capabilities after Webapps runtime install"
    bash "${AGENT_REPO_INSTALLER}" --install-label "${install_label}"
    return 0
  fi

  log "mnscloud-agent source repo not found at ${AGENT_REPO_INSTALLER}; restarting service so runtime capability detection can refresh"
  systemctl restart mnscloud-agent || true
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
ensure_release_tools

install -d -m 0755 "$WEBAPPS_ROOT" \
  "$WEBAPPS_ROOT/repos" \
  "$WEBAPPS_ROOT/releases" \
  "$WEBAPPS_ROOT/current" \
  "$WEBAPPS_ROOT/runtime/logs" \
  "$WEBAPPS_ENV_DIR/apps.d" \
  "$WEBAPPS_ENV_DIR/nginx/apps" \
  "$WEBAPPS_ENV_DIR/nginx/servers"

for example in "${ROOT_DIR}"/config/apps.d/*.env.example; do
  target="${WEBAPPS_APPS_DIR}/$(basename "${example%.example}")"
  [[ -f "$target" ]] || install -m 0640 "$example" "$target"
done

ensure_flutter_if_required
render_runtime_nginx
render_runtime_units

chown -R "$WEBAPPS_USER:$WEBAPPS_GROUP" "$WEBAPPS_ROOT"
systemctl enable mnscloud-webapps.service
webapps_nginx -t
systemctl restart mnscloud-webapps.service
refresh_agent_capabilities

log "installed webapps runtime on ${WEBAPPS_LISTEN_HOST}:${WEBAPPS_LISTEN_PORT}"
log "review ${WEBAPPS_APPS_DIR}/*.env, then install apps with scripts/update-webapps.sh --env ${ENV_FILE}"
