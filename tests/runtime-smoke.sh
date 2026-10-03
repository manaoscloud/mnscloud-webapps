#!/usr/bin/env bash
# End-to-end smoke test of APP_SOURCE=release installs, path- and host-based nginx rendering,
# checksum enforcement, the client allowlist and rollback. Runs against a local fake GitHub
# (python3) and a real nginx bound to 127.0.0.1; systemctl is stubbed.
#
# Requirements: root (creates the service user and /run/lock), nginx, python3, curl, tar.
#   sudo bash tests/runtime-smoke.sh
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
chmod 0755 "$WORK" # nginx workers run unprivileged and must traverse the runtime root
PORT="${SMOKE_PORT:-18080}"
GH_PORT="${SMOKE_GH_PORT:-18081}"
NGINX_STARTED=0

cleanup() {
  if [[ "$NGINX_STARTED" == "1" ]]; then
    nginx -p "${WORK}/root/runtime" -c "${WORK}/root/runtime/nginx.conf" -s quit 2>/dev/null || true
  fi
  [[ -n "${GH_PID:-}" ]] && kill "$GH_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '[smoke] ok - %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || fail "run as root"
for tool in nginx python3 curl tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

# --- stubs: systemctl reloads the real test nginx; everything else is a no-op ---------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "reload" && "\$2" == "mnscloud-webapps.service" && -f "${WORK}/root/runtime/nginx.pid" ]]; then
  nginx -p "${WORK}/root/runtime" -c "${WORK}/root/runtime/nginx.conf" -s reload
  sleep 1 # reload is asynchronous; let the new workers take over before the next request
fi
exit 0
EOF
chmod +x "${WORK}/bin/systemctl"
export PATH="${WORK}/bin:${PATH}"

# --- fake GitHub releases -------------------------------------------------------------------
make_release() {
  local repo="$1" tag="$2" marker="$3" base_href="$4" tamper="${5:-0}"
  local version="${tag#v}"
  local name="${repo##*/}-web-v${version}.tar.gz"
  local src="${WORK}/src/${repo}/${tag}"
  local out="${WORK}/gh/${repo}/releases/download/${tag}"
  mkdir -p "$src/assets" "$out"
  if [[ -n "$base_href" ]]; then
    printf '<!doctype html><html><head><base href="%s"></head><body>%s</body></html>\n' "$base_href" "$marker" > "$src/index.html"
  else
    printf '<!doctype html><html><body>%s</body></html>\n' "$marker" > "$src/index.html"
    printf 'not found\n' > "$src/404.html"
    mkdir -p "$src/_astro" "$src/about"
    printf 'body{}\n' > "$src/_astro/app.123.css"
    printf 'about %s\n' "$marker" > "$src/about/index.html"
  fi
  printf 'console.log("%s")\n' "$marker" > "$src/assets/app.js"
  tar -C "$src" -czf "${out}/${name}" .
  if [[ "$tamper" == "1" ]]; then
    printf '%064d  %s\n' 0 "$name" > "${out}/${name}.sha256"
  else
    (cd "$out" && sha256sum "$name" > "${name}.sha256")
  fi
}

make_release demo/mnscloud-phoneweb v1.0.0 phoneweb-one "/"
make_release demo/mnscloud-phoneweb v1.1.0 phoneweb-two "/"
make_release demo/mnscloud-website v2.0.0 website-one ""
make_release demo/mnscloud-tampered v0.0.1 tampered "/" 1

cat > "${WORK}/gh-server.py" <<'PY'
import http.server
import os
import sys

ROOT, PORT, LATEST = sys.argv[1], int(sys.argv[2]), dict(a.split("=", 1) for a in sys.argv[3:])

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_HEAD(self):
        if self.path.endswith("/releases/latest"):
            repo = self.path[1:-len("/releases/latest")]
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{PORT}/{repo}/releases/tag/{LATEST[repo]}")
            self.end_headers()
            return
        super().do_HEAD()

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
python3 "${WORK}/gh-server.py" "${WORK}/gh" "$GH_PORT" \
  "demo/mnscloud-phoneweb=v1.1.0" "demo/mnscloud-website=v2.0.0" &
GH_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:${GH_PORT}/" && break
  sleep 0.1
done

# --- runtime configuration ------------------------------------------------------------------
mkdir -p "${WORK}/etc/apps.d"
cat > "${WORK}/etc/webapps.env" <<EOF
WEBAPPS_ROOT=${WORK}/root
WEBAPPS_ENV_DIR=${WORK}/etc
WEBAPPS_APPS_DIR=${WORK}/etc/apps.d
WEBAPPS_LISTEN_HOST=127.0.0.1
WEBAPPS_LISTEN_PORT=${PORT}
WEBAPPS_ALLOWED_CLIENTS=192.0.2.10
WEBAPPS_GITHUB_BASE_URL=http://127.0.0.1:${GH_PORT}
WEBAPPS_ENABLED_APPS=phoneweb,website
WEBAPPS_KEEP_RELEASES=1
WEBAPPS_INSTALL_FLUTTER=auto
EOF
cat > "${WORK}/etc/apps.d/phoneweb.env" <<'EOF'
APP_NAME=phoneweb
APP_BASE_PATH=/phoneweb/
APP_SOURCE=release
APP_RELEASE_REPOSITORY=demo/mnscloud-phoneweb
APP_REF=v1.0.0
EOF
cat > "${WORK}/etc/apps.d/website.env" <<'EOF'
APP_NAME=website
APP_SERVER_NAME=www.example.test example.test
APP_SOURCE=release
APP_RELEASE_REPOSITORY=demo/mnscloud-website
APP_REF=latest
APP_IMMUTABLE_PATHS=/_astro/
EOF
cat > "${WORK}/etc/apps.d/tampered.env" <<'EOF'
APP_NAME=tampered
APP_SOURCE=release
APP_RELEASE_REPOSITORY=demo/mnscloud-tampered
APP_REF=v0.0.1
EOF
ENV="${WORK}/etc/webapps.env"

# Flutter must not be required when every enabled app is a release artifact.
(
  # shellcheck source=../scripts/lib/common.sh
  source "${ROOT_DIR}/scripts/lib/common.sh"
  ENV_FILE="$ENV"
  load_runtime_env
  ! enabled_apps_need_flutter
) || fail "release-only apps must not require Flutter"
pass "WEBAPPS_INSTALL_FLUTTER=auto skips Flutter for release-only apps"

# --- install pinned path-based app, start nginx ---------------------------------------------
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app phoneweb >/dev/null
nginx -p "${WORK}/root/runtime" -c "${WORK}/root/runtime/nginx.conf"
NGINX_STARTED=1
base="http://127.0.0.1:${PORT}"

[[ "$(curl -fsS "${base}/healthz")" == "ok" ]] || fail "healthz"
body="$(curl -fsS "${base}/phoneweb/")"
[[ "$body" == *phoneweb-one* ]] || fail "phoneweb v1.0.0 not served"
[[ "$body" == *'<base href="/phoneweb/">'* ]] || fail "base href not rewritten to /phoneweb/"
[[ "$(curl -fsS "${base}/phoneweb/some/deep/route")" == *phoneweb-one* ]] || fail "SPA fallback"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${base}/phoneweb")" == "301" ]] || fail "no-slash redirect"
curl -fsSI "${base}/phoneweb/assets/app.js" | grep -qi '^cache-control: no-cache' || fail "no-cache header"
[[ -f "${WORK}/root/releases/phoneweb/v1.0.0.json" ]] || fail "release record missing"
pass "pinned release installed, verified, base href rewritten, SPA fallback, cache headers"

# --- host-based app with "latest" -----------------------------------------------------------
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app website >/dev/null
[[ "$(readlink "${WORK}/root/current/website")" == */v2.0.0 ]] || fail "latest not resolved to v2.0.0"
[[ "$(curl -fsS -H 'Host: www.example.test' "${base}/")" == *website-one* ]] || fail "website root"
[[ "$(curl -fsS -H 'Host: example.test' "${base}/about/")" == *"about website-one"* ]] || fail "website subpage"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: www.example.test' "${base}/missing")" == "404" ]] || fail "website 404"
curl -fsSI -H 'Host: www.example.test' "${base}/_astro/app.123.css" | grep -qi 'immutable' || fail "immutable cache"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: www.example.test' "${base}/.env")" == "404" ]] || fail "dotfile blocked"
[[ "$(curl -fsS -H 'Host: unknown.test' "${base}/healthz")" == "ok" ]] || fail "default server for unknown hosts"
pass "host-based app resolved latest, serves root/subpages/404, immutable assets, dotfiles blocked"

# --- allowlist rendered -----------------------------------------------------------------------
grep -qx 'allow 192.0.2.10;' "${WORK}/etc/nginx/access.conf" || fail "allowlist entry"
grep -qx 'deny all;' "${WORK}/etc/nginx/access.conf" || fail "allowlist deny"
pass "client allowlist rendered"

# --- idempotent re-run ------------------------------------------------------------------------
out="$(bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app website 2>&1)"
[[ "$out" == *"already active"* ]] || fail "re-run should be a no-op: $out"
pass "re-run at the same release is a no-op"

# --- tampered checksum is rejected and does not change anything ------------------------------
if bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app tampered >/dev/null 2>&1; then
  fail "tampered artifact was accepted"
fi
[[ ! -e "${WORK}/root/current/tampered" ]] || fail "tampered artifact activated"
pass "checksum mismatch rejected"

# --- sync moves the pinned app forward after APP_REF=latest, prune + rollback ----------------
sed -i 's/^APP_REF=.*/APP_REF=latest/' "${WORK}/etc/apps.d/phoneweb.env"
sleep 1
bash "${ROOT_DIR}/scripts/sync-webapps.sh" --env "$ENV" >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-two* ]] || fail "sync did not install v1.1.0"
[[ -d "${WORK}/root/releases/phoneweb/v1.0.0" ]] || fail "previous release must be kept (active + KEEP=1)"
bash "${ROOT_DIR}/scripts/rollback-webapps.sh" --env "$ENV" --app phoneweb >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-one* ]] || fail "rollback did not restore v1.0.0"
pass "sync installs latest, rollback restores the previous release"

bash "${ROOT_DIR}/scripts/validate-webapps.sh" --env "$ENV" >/dev/null || fail "validate-webapps.sh"
pass "validate-webapps.sh passes for all enabled apps"

printf '[smoke] all checks passed\n'
