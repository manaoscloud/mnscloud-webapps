#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_ENV_FILE="/etc/mnscloud/webapps/webapps.env"

log() { printf '[mnscloud-webapps] %s\n' "$*"; }
die() { printf '[mnscloud-webapps] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ "${EUID}" -eq 0 ]] || die "this command must run as root"; }

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  case "${OS_ID}:${OS_VERSION_ID}" in
    debian:12|debian:13) OS_FAMILY="debian" ;;
    rhel:9*|rhel:10*|rocky:9*|rocky:10*|almalinux:9*|almalinux:10*) OS_FAMILY="rhel" ;;
    *) die "unsupported OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}. Supported: Debian 12/13 and RHEL/Rocky/AlmaLinux 9/10" ;;
  esac
}

install_nginx_org_repository() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
      | gpg --dearmor \
      | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    local codename="${OS_VERSION_CODENAME:-}"
    if [[ -z "$codename" ]]; then
      codename="$(lsb_release -cs)"
    fi

    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian ${codename} nginx
EOF

    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF
  else
    dnf install -y yum-utils ca-certificates curl
    cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  fi
}

install_nginx_package() {
  if command -v nginx >/dev/null 2>&1; then
    return 0
  fi

  detect_os
  log "nginx not found; configuring official nginx.org repository"
  install_nginx_org_repository
  log "installing nginx from official nginx.org repository"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y nginx
  else
    dnf install -y nginx
  fi

  command -v nginx >/dev/null 2>&1 || die "nginx installation failed"
}

disable_default_nginx_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl disable --now nginx.service >/dev/null 2>&1 || true
  fi
}

load_env_file() {
  local env_file="${1:-$DEFAULT_ENV_FILE}"
  local line key value
  [[ -f "$env_file" ]] || die "env file not found: $env_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#export }"
    [[ "$line" == *"="* ]] || die "invalid env line in ${env_file}: ${line}"
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid env key in ${env_file}: ${key}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    export "${key}=${value}"
  done < "$env_file"
}

parse_env_arg() {
  ENV_FILE="$DEFAULT_ENV_FILE"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) ENV_FILE="${2:-}"; shift 2 ;;
      --help|-h) return 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

load_runtime_env() {
  load_env_file "${ENV_FILE:-$DEFAULT_ENV_FILE}"
  WEBAPPS_ROOT="${WEBAPPS_ROOT:-/opt/mnscloud/webapps}"
  WEBAPPS_ENV_DIR="${WEBAPPS_ENV_DIR:-/etc/mnscloud/webapps}"
  WEBAPPS_APPS_DIR="${WEBAPPS_APPS_DIR:-${WEBAPPS_ENV_DIR}/apps.d}"
  WEBAPPS_LISTEN_HOST="${WEBAPPS_LISTEN_HOST:-127.0.0.1}"
  WEBAPPS_LISTEN_PORT="${WEBAPPS_LISTEN_PORT:-8080}"
  WEBAPPS_USER="${WEBAPPS_USER:-mnscloud-webapps}"
  WEBAPPS_GROUP="${WEBAPPS_GROUP:-mnscloud-webapps}"
  WEBAPPS_ENABLED_APPS="${WEBAPPS_ENABLED_APPS:-}"
}

normalize_base_path() {
  local path="$1"
  [[ "$path" == /* ]] || path="/$path"
  [[ "$path" == */ ]] || path="$path/"
  printf '%s' "$path"
}

load_app_env() {
  local app="$1"
  [[ "$app" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid app name: $app"
  local app_env="${WEBAPPS_APPS_DIR}/${app}.env"
  [[ -f "$app_env" ]] || die "app env file not found: $app_env"

  unset APP_NAME APP_REPO_URL APP_REF APP_BASE_PATH APP_PUBLIC_API_BASE_URL APP_BUILD_COMMAND
  load_env_file "$app_env"

  APP_NAME="${APP_NAME:-$app}"
  [[ "$APP_NAME" == "$app" ]] || die "APP_NAME must match app env filename: $app"
  [[ -n "${APP_REPO_URL:-}" ]] || die "APP_REPO_URL is required for $app"
  APP_REF="${APP_REF:-main}"
  APP_BASE_PATH="$(normalize_base_path "${APP_BASE_PATH:-/$app/}")"
  APP_PUBLIC_API_BASE_URL="${APP_PUBLIC_API_BASE_URL:-/api/v1}"
  APP_REPO_DIR="${WEBAPPS_ROOT}/repos/${APP_NAME}"
  APP_RELEASES_DIR="${WEBAPPS_ROOT}/releases/${APP_NAME}"
  APP_CURRENT_LINK="${WEBAPPS_ROOT}/current/${APP_NAME}"
}

render_runtime_nginx() {
  install -d -m 0755 "${WEBAPPS_ROOT}/runtime/logs" "${WEBAPPS_ENV_DIR}/nginx/apps"
  local template="${ROOT_DIR}/config/nginx/nginx.conf.template"
  sed \
    -e "s|{{WEBAPPS_ROOT}}|${WEBAPPS_ROOT}|g" \
    -e "s|{{WEBAPPS_ENV_DIR}}|${WEBAPPS_ENV_DIR}|g" \
    -e "s|{{WEBAPPS_LISTEN_HOST}}|${WEBAPPS_LISTEN_HOST}|g" \
    -e "s|{{WEBAPPS_LISTEN_PORT}}|${WEBAPPS_LISTEN_PORT}|g" \
    "$template" > "${WEBAPPS_ROOT}/runtime/nginx.conf"
}

render_app_nginx() {
  local app="$1"
  load_app_env "$app"
  install -d -m 0755 "${WEBAPPS_ENV_DIR}/nginx/apps"
  local no_slash="${APP_BASE_PATH%/}"
  local app_conf="${WEBAPPS_ENV_DIR}/nginx/apps/${APP_NAME}.conf"
  cat > "$app_conf" <<EOF
location = ${no_slash} {
  return 301 ${APP_BASE_PATH};
}

location ^~ ${APP_BASE_PATH} {
  root ${WEBAPPS_ROOT}/current;
  try_files \$uri \$uri/ ${APP_BASE_PATH}index.html;
  add_header Cache-Control "no-store" always;
}
EOF
}

webapps_nginx() {
  command -v nginx >/dev/null 2>&1 || die "nginx is required"
  nginx -p "${WEBAPPS_ROOT}/runtime" -c "${WEBAPPS_ROOT}/runtime/nginx.conf" "$@"
}

ensure_service_user() {
  if ! getent group "$WEBAPPS_GROUP" >/dev/null; then
    groupadd --system "$WEBAPPS_GROUP"
  fi
  if ! id -u "$WEBAPPS_USER" >/dev/null 2>&1; then
    useradd --system --home "$WEBAPPS_ROOT" --shell /usr/sbin/nologin \
      --gid "$WEBAPPS_GROUP" "$WEBAPPS_USER"
  fi
}

enabled_apps() {
  local app
  IFS=',' read -ra apps <<< "${WEBAPPS_ENABLED_APPS:-}"
  for app in "${apps[@]}"; do
    app="${app#"${app%%[![:space:]]*}"}"
    app="${app%"${app##*[![:space:]]}"}"
    [[ -n "$app" ]] && printf '%s\n' "$app"
  done
}
