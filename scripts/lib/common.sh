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

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  detect_os
  log "git not found; installing git"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y git ca-certificates
  else
    dnf install -y git ca-certificates
  fi
}

ensure_runtime_kit() {
  WEBAPPS_RUNTIME_KIT_DIR="${WEBAPPS_RUNTIME_KIT_DIR:-/opt/mnscloud/runtime-kit}"
  WEBAPPS_RUNTIME_KIT_REPO_URL="${WEBAPPS_RUNTIME_KIT_REPO_URL:-https://github.com/manaoscloud/mnscloud-runtime-kit.git}"
  WEBAPPS_RUNTIME_KIT_REF="${WEBAPPS_RUNTIME_KIT_REF:-}"
  WEBAPPS_RUNTIME_KIT_CHANNEL="${WEBAPPS_RUNTIME_KIT_CHANNEL:-stable}"

  ensure_git

  if [[ -d "${WEBAPPS_RUNTIME_KIT_DIR}/.git" ]]; then
    log "updating runtime kit in ${WEBAPPS_RUNTIME_KIT_DIR}"
    git -C "$WEBAPPS_RUNTIME_KIT_DIR" fetch --all --tags --prune
  else
    log "installing runtime kit in ${WEBAPPS_RUNTIME_KIT_DIR}"
    install -d -m 0755 "$(dirname "$WEBAPPS_RUNTIME_KIT_DIR")"
    git clone "$WEBAPPS_RUNTIME_KIT_REPO_URL" "$WEBAPPS_RUNTIME_KIT_DIR"
  fi

  if [[ -z "$WEBAPPS_RUNTIME_KIT_REF" ]]; then
    WEBAPPS_RUNTIME_KIT_REF="$(resolve_runtime_kit_ref "$WEBAPPS_RUNTIME_KIT_DIR" "$WEBAPPS_RUNTIME_KIT_CHANNEL")"
    log "resolved runtime kit ${WEBAPPS_RUNTIME_KIT_CHANNEL} channel to ${WEBAPPS_RUNTIME_KIT_REF}"
  fi

  git -C "$WEBAPPS_RUNTIME_KIT_DIR" -c advice.detachedHead=false checkout "$WEBAPPS_RUNTIME_KIT_REF"
  git -C "$WEBAPPS_RUNTIME_KIT_DIR" pull --ff-only origin "$WEBAPPS_RUNTIME_KIT_REF" 2>/dev/null || true
  [[ -r "${WEBAPPS_RUNTIME_KIT_DIR}/lib/packages.sh" ]] || die "runtime kit packages library not found"
}

resolve_runtime_kit_ref() {
  local kit_dir="$1"
  local channel="$2"
  local manifest ref

  manifest="$(git -C "$kit_dir" show "origin/main:releases/manifest.json" 2>/dev/null)" ||
    die "cannot read runtime kit release manifest from origin/main"
  ref="$(printf '%s\n' "$manifest" | awk -v channel="$channel" '
    $0 ~ "\"" channel "\"" { in_channel = 1; next }
    in_channel && /"ref"[[:space:]]*:/ {
      gsub(/.*"ref"[[:space:]]*:[[:space:]]*"/, "")
      gsub(/".*/, "")
      print
      exit
    }
    in_channel && /^[[:space:]]*}/ { in_channel = 0 }
  ')"
  [[ "$ref" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    die "invalid runtime kit ref for channel ${channel}: ${ref:-empty}"
  printf '%s\n' "$ref"
}

load_runtime_kit() {
  ensure_runtime_kit
  export MNSCLOUD_RUNTIME_KIT_LOG_PREFIX="mnscloud-webapps/runtime-kit"
  # shellcheck disable=SC1091
  source "${WEBAPPS_RUNTIME_KIT_DIR}/lib/packages.sh"
}

install_nginx_package() {
  load_runtime_kit
  mrtk_install_nginx_package
}

install_flutter_dependencies() {
  load_runtime_kit
  mrtk_install_flutter_dependencies
}

install_or_update_flutter() {
  load_runtime_kit
  export MNSCLOUD_FLUTTER_DIR="${WEBAPPS_FLUTTER_DIR:-/opt/flutter}"
  export MNSCLOUD_FLUTTER_CHANNEL="${WEBAPPS_FLUTTER_CHANNEL:-stable}"
  export MNSCLOUD_FLUTTER_BUILD_PROFILE="${WEBAPPS_FLUTTER_BUILD_PROFILE:-web}"
  export MNSCLOUD_FLUTTER_RUN_USER="${WEBAPPS_FLUTTER_RUN_USER:-$WEBAPPS_USER}"
  export MNSCLOUD_FLUTTER_HOME="${WEBAPPS_FLUTTER_HOME:-/var/lib/mnscloud-webapps/flutter}"
  export MNSCLOUD_FLUTTER_PRECACHE_WEB=true
  mrtk_install_or_update_flutter
}

ensure_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${WEBAPPS_INSTALL_FLUTTER:-true}" != "true" ]]; then
    die "flutter is required. Install Flutter or set WEBAPPS_INSTALL_FLUTTER=true."
  fi

  load_runtime_kit
  export MNSCLOUD_FLUTTER_DIR="${WEBAPPS_FLUTTER_DIR:-/opt/flutter}"
  export MNSCLOUD_FLUTTER_CHANNEL="${WEBAPPS_FLUTTER_CHANNEL:-stable}"
  export MNSCLOUD_FLUTTER_BUILD_PROFILE="${WEBAPPS_FLUTTER_BUILD_PROFILE:-web}"
  export MNSCLOUD_FLUTTER_RUN_USER="${WEBAPPS_FLUTTER_RUN_USER:-$WEBAPPS_USER}"
  export MNSCLOUD_FLUTTER_HOME="${WEBAPPS_FLUTTER_HOME:-/var/lib/mnscloud-webapps/flutter}"
  export MNSCLOUD_FLUTTER_PRECACHE_WEB=true
  mrtk_ensure_flutter
  command -v flutter >/dev/null 2>&1 || die "Flutter installation failed"
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
  WEBAPPS_RUNTIME_KIT_DIR="${WEBAPPS_RUNTIME_KIT_DIR:-/opt/mnscloud/runtime-kit}"
  WEBAPPS_RUNTIME_KIT_REPO_URL="${WEBAPPS_RUNTIME_KIT_REPO_URL:-https://github.com/manaoscloud/mnscloud-runtime-kit.git}"
  WEBAPPS_RUNTIME_KIT_CHANNEL="${WEBAPPS_RUNTIME_KIT_CHANNEL:-stable}"
  WEBAPPS_RUNTIME_KIT_REF="${WEBAPPS_RUNTIME_KIT_REF:-}"
  WEBAPPS_INSTALL_FLUTTER="${WEBAPPS_INSTALL_FLUTTER:-true}"
  WEBAPPS_FLUTTER_DIR="${WEBAPPS_FLUTTER_DIR:-/opt/flutter}"
  WEBAPPS_FLUTTER_CHANNEL="${WEBAPPS_FLUTTER_CHANNEL:-stable}"
  WEBAPPS_FLUTTER_BUILD_PROFILE="${WEBAPPS_FLUTTER_BUILD_PROFILE:-web}"
  WEBAPPS_FLUTTER_RUN_USER="${WEBAPPS_FLUTTER_RUN_USER:-$WEBAPPS_USER}"
  WEBAPPS_FLUTTER_HOME="${WEBAPPS_FLUTTER_HOME:-/var/lib/mnscloud-webapps/flutter}"
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

run_as_webapps_user() {
  local home="${WEBAPPS_FLUTTER_HOME:-/var/lib/mnscloud-webapps/flutter}"
  install -d -m 0750 -o "$WEBAPPS_USER" -g "$WEBAPPS_GROUP" "$home"
  runuser -u "$WEBAPPS_USER" -- env \
    HOME="$home" \
    PUB_CACHE="${home}/.pub-cache" \
    PATH="${WEBAPPS_FLUTTER_DIR}/bin:${PATH}" \
    "$@"
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
