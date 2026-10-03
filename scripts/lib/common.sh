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
  WEBAPPS_INSTALL_FLUTTER="${WEBAPPS_INSTALL_FLUTTER:-auto}"
  WEBAPPS_FLUTTER_DIR="${WEBAPPS_FLUTTER_DIR:-/opt/flutter}"
  WEBAPPS_FLUTTER_CHANNEL="${WEBAPPS_FLUTTER_CHANNEL:-stable}"
  WEBAPPS_FLUTTER_BUILD_PROFILE="${WEBAPPS_FLUTTER_BUILD_PROFILE:-web}"
  WEBAPPS_FLUTTER_RUN_USER="${WEBAPPS_FLUTTER_RUN_USER:-$WEBAPPS_USER}"
  WEBAPPS_FLUTTER_HOME="${WEBAPPS_FLUTTER_HOME:-/var/lib/mnscloud-webapps/flutter}"
  WEBAPPS_ENABLED_APPS="${WEBAPPS_ENABLED_APPS:-}"
  WEBAPPS_ALLOWED_CLIENTS="${WEBAPPS_ALLOWED_CLIENTS:-}"
  WEBAPPS_GITHUB_BASE_URL="${WEBAPPS_GITHUB_BASE_URL:-https://github.com}"
  WEBAPPS_GITHUB_BASE_URL="${WEBAPPS_GITHUB_BASE_URL%/}"
  [[ "$WEBAPPS_GITHUB_BASE_URL" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._/-]*)?$ ]] ||
    die "invalid WEBAPPS_GITHUB_BASE_URL"
  WEBAPPS_KEEP_RELEASES="${WEBAPPS_KEEP_RELEASES:-5}"
  WEBAPPS_AUTO_SYNC="${WEBAPPS_AUTO_SYNC:-false}"
  WEBAPPS_AUTO_SYNC_INTERVAL="${WEBAPPS_AUTO_SYNC_INTERVAL:-15min}"
  [[ "$WEBAPPS_KEEP_RELEASES" =~ ^[1-9][0-9]*$ ]] || die "WEBAPPS_KEEP_RELEASES must be a positive integer"
  [[ "$WEBAPPS_AUTO_SYNC_INTERVAL" =~ ^[0-9]+(s|min|h)$ ]] ||
    die "WEBAPPS_AUTO_SYNC_INTERVAL must look like 900s, 15min or 1h"
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

  unset APP_NAME APP_REPO_URL APP_REF APP_BASE_PATH APP_PUBLIC_API_BASE_URL APP_BUILD_COMMAND \
    APP_SOURCE APP_RELEASE_REPOSITORY APP_RELEASE_ASSET_PREFIX APP_SERVER_NAME APP_IMMUTABLE_PATHS
  load_env_file "$app_env"

  APP_NAME="${APP_NAME:-$app}"
  [[ "$APP_NAME" == "$app" ]] || die "APP_NAME must match app env filename: $app"
  APP_SOURCE="${APP_SOURCE:-build}"
  case "$APP_SOURCE" in
    build)
      [[ -n "${APP_REPO_URL:-}" ]] || die "APP_REPO_URL is required for $app (APP_SOURCE=build)"
      APP_REF="${APP_REF:-main}"
      ;;
    release)
      [[ "${APP_RELEASE_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "APP_RELEASE_REPOSITORY must be <owner>/<repo> for $app (APP_SOURCE=release)"
      APP_RELEASE_ASSET_PREFIX="${APP_RELEASE_ASSET_PREFIX:-${APP_RELEASE_REPOSITORY##*/}-web-v}"
      [[ "$APP_RELEASE_ASSET_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
        die "invalid APP_RELEASE_ASSET_PREFIX for $app"
      APP_REF="${APP_REF:-latest}"
      [[ "$APP_REF" == "latest" || "$APP_REF" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
        die "APP_REF must be 'latest' or a release tag such as v1.2.3 for $app (APP_SOURCE=release)"
      ;;
    *) die "APP_SOURCE must be 'build' or 'release' for $app" ;;
  esac
  APP_SERVER_NAME="${APP_SERVER_NAME:-}"
  local entry
  for entry in $APP_SERVER_NAME; do
    [[ "$entry" =~ ^[A-Za-z0-9*]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
      die "invalid APP_SERVER_NAME entry for $app: $entry"
  done
  [[ -n "$APP_SERVER_NAME" ]] && APP_BASE_PATH="/"
  APP_IMMUTABLE_PATHS="${APP_IMMUTABLE_PATHS:-}"
  for entry in $APP_IMMUTABLE_PATHS; do
    [[ "$entry" =~ ^/[A-Za-z0-9._/-]*/$ ]] ||
      die "APP_IMMUTABLE_PATHS entries must look like /_astro/ for $app"
  done
  APP_BASE_PATH="$(normalize_base_path "${APP_BASE_PATH:-/$app/}")"
  [[ "$APP_BASE_PATH" =~ ^/([A-Za-z0-9._-]+/)*$ ]] || die "invalid APP_BASE_PATH for $app"
  APP_PUBLIC_API_BASE_URL="${APP_PUBLIC_API_BASE_URL:-/api/v1}"
  APP_REPO_DIR="${WEBAPPS_ROOT}/repos/${APP_NAME}"
  APP_RELEASES_DIR="${WEBAPPS_ROOT}/releases/${APP_NAME}"
  APP_CURRENT_LINK="${WEBAPPS_ROOT}/current/${APP_NAME}"
}

render_access_rules() {
  local rules="${WEBAPPS_ENV_DIR}/nginx/access.conf"
  local entry
  local -a entries=()
  {
    printf '# Generated by mnscloud-webapps from WEBAPPS_ALLOWED_CLIENTS. Do not edit.\n'
    if [[ -z "${WEBAPPS_ALLOWED_CLIENTS//[[:space:],]/}" ]]; then
      printf '# No client allowlist configured; restrict the listen port with the host firewall.\n'
    else
      printf 'allow 127.0.0.1;\nallow ::1;\n'
      if [[ "$WEBAPPS_LISTEN_HOST" != "0.0.0.0" && "$WEBAPPS_LISTEN_HOST" != "127.0.0.1" ]]; then
        printf 'allow %s;\n' "$WEBAPPS_LISTEN_HOST"
      fi
      IFS=',' read -ra entries <<< "$WEBAPPS_ALLOWED_CLIENTS"
      for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        [[ -n "$entry" ]] || continue
        [[ "$entry" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] ||
          die "invalid WEBAPPS_ALLOWED_CLIENTS entry: $entry"
        printf 'allow %s;\n' "$entry"
      done
      printf 'deny all;\n'
    fi
  } > "$rules"
}

render_runtime_nginx() {
  install -d -m 0755 "${WEBAPPS_ROOT}/runtime/logs" "${WEBAPPS_ENV_DIR}/nginx/apps" \
    "${WEBAPPS_ENV_DIR}/nginx/servers"
  render_access_rules
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
  install -d -m 0755 "${WEBAPPS_ENV_DIR}/nginx/apps" "${WEBAPPS_ENV_DIR}/nginx/servers"
  local path_conf="${WEBAPPS_ENV_DIR}/nginx/apps/${APP_NAME}.conf"
  local server_conf="${WEBAPPS_ENV_DIR}/nginx/servers/${APP_NAME}.conf"
  local immutable immutable_locations=""
  for immutable in $APP_IMMUTABLE_PATHS; do
    immutable_locations+="
  location ^~ ${immutable} {
    try_files \$uri =404;
    add_header Cache-Control \"public, max-age=31536000, immutable\" always;
  }
"
  done

  if [[ -n "$APP_SERVER_NAME" ]]; then
    rm -f "$path_conf"
    cat > "$server_conf" <<EOF
server {
  listen ${WEBAPPS_LISTEN_HOST}:${WEBAPPS_LISTEN_PORT};
  server_name ${APP_SERVER_NAME};
  root ${WEBAPPS_ROOT}/current/${APP_NAME};
  index index.html;

  location ~ (^|/)\. {
    return 404;
  }
${immutable_locations}
  location / {
    try_files \$uri \$uri/ \$uri.html =404;
    add_header Cache-Control "no-cache" always;
  }

  error_page 404 /404.html;
}
EOF
    return 0
  fi

  rm -f "$server_conf"
  local no_slash="${APP_BASE_PATH%/}"
  cat > "$path_conf" <<EOF
location = ${no_slash} {
  return 301 ${APP_BASE_PATH};
}

location ^~ ${APP_BASE_PATH} {
  root ${WEBAPPS_ROOT}/current;
  try_files \$uri \$uri/ ${APP_BASE_PATH}index.html;
  add_header Cache-Control "no-cache" always;
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

is_true() {
  [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

enabled_apps_need_flutter() {
  local app
  while IFS= read -r app; do
    [[ -n "$app" && -f "${WEBAPPS_APPS_DIR}/${app}.env" ]] || continue
    load_app_env "$app"
    [[ "$APP_SOURCE" == "build" ]] && return 0
  done < <(enabled_apps)
  return 1
}

# Installs Flutter when WEBAPPS_INSTALL_FLUTTER=true, or when it is "auto" and an enabled app still
# builds from source. Hosts that only install prebuilt release artifacts skip the SDK entirely.
ensure_flutter_if_required() {
  case "${WEBAPPS_INSTALL_FLUTTER:-auto}" in
    true) ensure_flutter ;;
    auto)
      if enabled_apps_need_flutter; then
        ensure_flutter
      else
        log "no enabled app builds from source; skipping Flutter"
      fi
      ;;
    false) log "WEBAPPS_INSTALL_FLUTTER=false; skipping Flutter" ;;
    *) die "WEBAPPS_INSTALL_FLUTTER must be auto, true or false" ;;
  esac
}

ensure_release_tools() {
  local -a missing=()
  local tool
  for tool in curl tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  detect_os
  log "installing release download tools: ${missing[*]}"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y curl tar coreutils ca-certificates
  else
    dnf install -y curl tar coreutils ca-certificates
  fi
}

# Resolves APP_REF for APP_SOURCE=release: a pinned tag is returned as-is; "latest" follows the
# public GitHub "latest release" redirect (no token and no rate-limited REST API call needed).
resolve_app_release_tag() {
  if [[ "$APP_REF" != "latest" ]]; then
    printf '%s\n' "$APP_REF"
    return 0
  fi
  local location tag
  location="$(curl -fsSI --max-time 30 "${WEBAPPS_GITHUB_BASE_URL}/${APP_RELEASE_REPOSITORY}/releases/latest" |
    tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -n1)"
  tag="${location##*/tag/}"
  [[ "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    die "cannot resolve the latest release of ${APP_RELEASE_REPOSITORY} (got: ${location:-empty})"
  printf '%s\n' "$tag"
}

current_app_release() {
  local target
  target="$(readlink "$APP_CURRENT_LINK" 2>/dev/null || true)"
  [[ -n "$target" ]] && basename "$target"
}

# Downloads <prefix><version>.tar.gz and its .sha256 sidecar from GitHub release <tag>, verifies
# the checksum, rejects unsafe archive paths and extracts it into releases/<app>/<tag>.
install_app_release_artifact() {
  local tag="$1"
  local version="${tag#v}"
  local asset="${APP_RELEASE_ASSET_PREFIX}${version}.tar.gz"
  local base_url="${WEBAPPS_GITHUB_BASE_URL}/${APP_RELEASE_REPOSITORY}/releases/download/${tag}"
  local target="${APP_RELEASES_DIR}/${tag}"

  if [[ -f "${target}/index.html" && -f "${APP_RELEASES_DIR}/${tag}.json" ]]; then
    log "${APP_NAME} ${tag} already downloaded"
    return 0
  fi

  local work expected actual
  work="$(mktemp -d)"
  log "downloading ${APP_NAME} ${tag} from ${APP_RELEASE_REPOSITORY}"
  if ! curl -fsSL --max-time 300 --retry 3 -o "${work}/${asset}" "${base_url}/${asset}" ||
    ! curl -fsSL --max-time 60 --retry 3 -o "${work}/${asset}.sha256" "${base_url}/${asset}.sha256"; then
    rm -rf "$work"
    die "cannot download ${asset} (and .sha256) from ${base_url}"
  fi

  expected="$(awk 'NR == 1 { print $1 }' "${work}/${asset}.sha256")"
  actual="$(sha256sum "${work}/${asset}" | awk '{ print $1 }')"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$actual" != "$expected" ]]; then
    rm -rf "$work"
    die "checksum verification failed for ${asset}: expected ${expected:-invalid}, got ${actual}"
  fi
  if tar -tzf "${work}/${asset}" | grep -Eq '(^/|(^|/)[.][.](/|$))'; then
    rm -rf "$work"
    die "refusing ${asset}: archive contains absolute or parent-directory paths"
  fi

  install -d -m 0755 "$APP_RELEASES_DIR"
  rm -rf "${target}.partial"
  install -d -m 0755 "${target}.partial"
  tar -xzf "${work}/${asset}" -C "${target}.partial" --no-same-owner --no-same-permissions
  rm -rf "$work"
  [[ -f "${target}.partial/index.html" ]] || die "${asset} does not contain index.html at its root"
  chmod -R u=rwX,go=rX "${target}.partial"
  rm -rf "$target"
  mv "${target}.partial" "$target"

  printf '{"app":"%s","repository":"%s","tag":"%s","asset":"%s","sha256":"%s","installedAt":"%s"}\n' \
    "$APP_NAME" "$APP_RELEASE_REPOSITORY" "$tag" "$asset" "$actual" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${APP_RELEASES_DIR}/${tag}.json"
}

# Release artifacts are built with a portable root base href; point it at the hosting path.
apply_app_base_href() {
  local index="$1/index.html"
  [[ "$APP_BASE_PATH" == "/" ]] && return 0
  grep -q '<base href="/">' "$index" || return 0
  sed -i "s|<base href=\"/\">|<base href=\"${APP_BASE_PATH}\">|" "$index"
}

activate_app_release() {
  local release_dir="$1"
  ln -sfn "$release_dir" "${APP_CURRENT_LINK}.next"
  mv -T "${APP_CURRENT_LINK}.next" "$APP_CURRENT_LINK"
  render_app_nginx "$APP_NAME"
  render_runtime_nginx
  webapps_nginx -t
  systemctl reload mnscloud-webapps.service 2>/dev/null || systemctl restart mnscloud-webapps.service
}

# Keeps the active release plus the newest WEBAPPS_KEEP_RELEASES other releases (by modification
# time), so a rollback target always remains available.
prune_app_releases() {
  local active name kept=0
  active="$(current_app_release || true)"
  while read -r _ name; do
    [[ "$name" == "$active" ]] && continue
    if (( kept < WEBAPPS_KEEP_RELEASES )); then
      kept=$((kept + 1))
      continue
    fi
    log "pruning old ${APP_NAME} release ${name}"
    rm -rf "${APP_RELEASES_DIR:?}/${name}" "${APP_RELEASES_DIR:?}/${name}.json"
  done < <(find "$APP_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -printf '%T@ %f\n' | sort -rn)
}

render_runtime_units() {
  local nginx_bin
  nginx_bin="$(command -v nginx || true)"
  [[ -n "$nginx_bin" ]] || die "nginx is required"
  cat > /etc/systemd/system/mnscloud-webapps.service <<EOF
[Unit]
Description=MNSCloud private webapps static runtime
After=network.target

[Service]
Type=forking
PIDFile=${WEBAPPS_ROOT}/runtime/nginx.pid
ExecStartPre=${nginx_bin} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -t
ExecStart=${nginx_bin} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf
ExecReload=${nginx_bin} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -s reload
ExecStop=${nginx_bin} -p ${WEBAPPS_ROOT}/runtime -c ${WEBAPPS_ROOT}/runtime/nginx.conf -s quit
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${WEBAPPS_ROOT} ${WEBAPPS_ENV_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/mnscloud-webapps-sync.service <<EOF
[Unit]
Description=MNSCloud webapps release artifact sync
After=network-online.target mnscloud-webapps.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${ROOT_DIR}/scripts/sync-webapps.sh --env ${ENV_FILE:-$DEFAULT_ENV_FILE}
EOF

  cat > /etc/systemd/system/mnscloud-webapps-sync.timer <<EOF
[Unit]
Description=Periodic MNSCloud webapps release artifact sync

[Timer]
OnBootSec=5min
OnUnitActiveSec=${WEBAPPS_AUTO_SYNC_INTERVAL}
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  if is_true "$WEBAPPS_AUTO_SYNC"; then
    systemctl enable --now mnscloud-webapps-sync.timer >/dev/null 2>&1
    log "release artifact auto sync enabled every ${WEBAPPS_AUTO_SYNC_INTERVAL}"
  else
    systemctl disable --now mnscloud-webapps-sync.timer >/dev/null 2>&1 || true
  fi
}

# Serializes runtime mutations (Agent update, auto sync, rollback). Nested calls inherit the lock.
acquire_webapps_lock() {
  [[ "${MNSCLOUD_WEBAPPS_LOCKED:-0}" == "1" ]] && return 0
  install -d -m 0755 /run/lock
  exec 9>/run/lock/mnscloud-webapps.lock
  flock -w 900 9 || die "another mnscloud-webapps operation is still running"
  export MNSCLOUD_WEBAPPS_LOCKED=1
}
