#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/build-app.sh --app <name> [--ref <git-ref|release-tag>] [--env /etc/mnscloud/webapps/webapps.env]

Installs one app according to its apps.d/<app>.env:
  APP_SOURCE=release  download the verified prebuilt artifact of release APP_REF (tag or "latest")
  APP_SOURCE=build    clone APP_REPO_URL at APP_REF and build it with Flutter on this host
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
APP=""
REF_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --ref) REF_OVERRIDE="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$APP" ]] || die "--app is required"
require_root
acquire_webapps_lock
load_runtime_env
ensure_service_user
load_app_env "$APP"
if [[ -n "$REF_OVERRIDE" ]]; then
  APP_REF="$REF_OVERRIDE"
  [[ "$APP_SOURCE" != "release" || "$APP_REF" == "latest" ||
    "$APP_REF" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    die "--ref must be 'latest' or a release tag for ${APP_NAME} (APP_SOURCE=release)"
fi
install -d -m 0755 "$APP_RELEASES_DIR" "$(dirname "$APP_CURRENT_LINK")"

nginx_config_digest() {
  cat "${WEBAPPS_ENV_DIR}"/nginx/*.conf "${WEBAPPS_ENV_DIR}"/nginx/apps/*.conf \
    "${WEBAPPS_ENV_DIR}"/nginx/servers/*.conf "${WEBAPPS_ROOT}/runtime/nginx.conf" 2>/dev/null |
    sha256sum | awk '{ print $1 }'
}

if [[ "$APP_SOURCE" == "release" ]]; then
  ensure_release_tools
  tag="$(resolve_app_release_tag)"

  if [[ "$(current_app_release || true)" == "$tag" && -f "${APP_CURRENT_LINK}/index.html" ]]; then
    before="$(nginx_config_digest)"
    render_app_nginx "$APP_NAME"
    render_runtime_nginx
    if [[ "$before" != "$(nginx_config_digest)" ]]; then
      webapps_nginx -t
      systemctl reload mnscloud-webapps.service 2>/dev/null || systemctl restart mnscloud-webapps.service
      log "${APP_NAME} ${tag} already active; nginx configuration refreshed"
    else
      log "${APP_NAME} ${tag} already active"
    fi
    exit 0
  fi

  install_app_release_artifact "$tag"
  release_dir="${APP_RELEASES_DIR}/${tag}"
  apply_app_base_href "$release_dir"
  activate_app_release "$release_dir"
  prune_app_releases
  log "${APP_NAME} ${tag} active at ${APP_SERVER_NAME:-$APP_BASE_PATH}"
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  install_flutter_dependencies
fi
ensure_flutter
command -v git >/dev/null 2>&1 || die "git is required"

install -d -m 0755 "$(dirname "$APP_REPO_DIR")"
if [[ ! -d "${APP_REPO_DIR}/.git" ]]; then
  log "cloning ${APP_NAME} from ${APP_REPO_URL}"
  git clone "$APP_REPO_URL" "$APP_REPO_DIR"
fi
chown -R "$WEBAPPS_USER:$WEBAPPS_GROUP" "$APP_REPO_DIR" "$APP_RELEASES_DIR"

cd "$APP_REPO_DIR"
run_as_webapps_user git fetch --all --tags --prune
run_as_webapps_user git checkout "$APP_REF"
run_as_webapps_user git pull --ff-only origin "$APP_REF" 2>/dev/null || true

log "installing Flutter dependencies for ${APP_NAME}"
run_as_webapps_user flutter pub get

if [[ -n "${APP_BUILD_COMMAND:-}" ]]; then
  log "building ${APP_NAME}: ${APP_BUILD_COMMAND}"
  run_as_webapps_user bash -lc "$APP_BUILD_COMMAND"
else
  log "building ${APP_NAME} with default Flutter web command"
  run_as_webapps_user flutter build web --release --base-href "$APP_BASE_PATH"
fi

[[ -d build/web ]] || die "build/web was not produced for ${APP_NAME}"

release_id="$(date -u +%Y%m%d%H%M%S)"
release_dir="${APP_RELEASES_DIR}/${release_id}"
install -d -m 0755 "$release_dir"
cp -a build/web/. "$release_dir/"
chown -R "$WEBAPPS_USER:$WEBAPPS_GROUP" "$release_dir"
activate_app_release "$release_dir"
prune_app_releases
log "${APP_NAME} built from ${APP_REF} and active as release ${release_id}"
