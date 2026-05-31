#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/build-app.sh --app <name> [--ref <git-ref>] [--env /etc/mnscloud/webapps/webapps.env]
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
load_runtime_env
ensure_service_user
load_app_env "$APP"
[[ -n "$REF_OVERRIDE" ]] && APP_REF="$REF_OVERRIDE"

if ! command -v git >/dev/null 2>&1; then
  install_flutter_dependencies
fi
ensure_flutter
command -v git >/dev/null 2>&1 || die "git is required"

install -d -m 0755 "$(dirname "$APP_REPO_DIR")" "$APP_RELEASES_DIR"
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
ln -sfn "$release_dir" "$APP_CURRENT_LINK"
chown -R "$WEBAPPS_USER:$WEBAPPS_GROUP" "$release_dir"

render_app_nginx "$APP_NAME"
render_runtime_nginx
webapps_nginx -t
systemctl reload mnscloud-webapps.service 2>/dev/null || systemctl restart mnscloud-webapps.service

log "${APP_NAME} updated to ${APP_REF} release ${release_id}"
