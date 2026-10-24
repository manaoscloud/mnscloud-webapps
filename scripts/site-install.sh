#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/site-install.sh --site <32-hex> --version <version> --archive <file.tar.gz> --sha256 <hex>
                               --host <fqdn> [--host <fqdn> ...] [--env /etc/mnscloud/webapps/webapps.env]

Installs the static snapshot of one hosted website (verified archive with index.html at its root),
swaps it in atomically and serves it on the given hosts with per-language 404 pages. A rejected nginx
configuration restores the previous release. Run by the Agent job website.site (install).
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
SITE="" VERSION="" ARCHIVE="" SHA256=""
HOSTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --sha256) SHA256="${2:-}"; shift 2 ;;
    --host) HOSTS+=("${2:-}"); shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$SITE" && -n "$VERSION" && -n "$ARCHIVE" && -n "$SHA256" && ${#HOSTS[@]} -gt 0 ]] ||
  { usage; die "--site, --version, --archive, --sha256 and --host are required"; }

require_root
acquire_webapps_lock
load_runtime_env
install_site "$SITE" "$VERSION" "$ARCHIVE" "$SHA256" "${HOSTS[@]}"
log "website ${SITE} ${VERSION} serving ${HOSTS[*]}"
