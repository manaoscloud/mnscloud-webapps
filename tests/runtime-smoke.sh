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
  [[ "$tag" == "v1.1.0" ]] && printf '{ "minimumVersion": "1.1.0" }\n' > "$src/update-policy.json"
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
WEBAPPS_ENABLED_APPS=phoneweb,website,pinned
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
APP_BASE_PATH=/
APP_ROUTING=static
APP_SOURCE=release
APP_RELEASE_REPOSITORY=demo/mnscloud-website
APP_REF=latest
APP_IMMUTABLE_PATHS=/_astro/
EOF
cat > "${WORK}/etc/apps.d/pinned.env" <<'EOF'
APP_NAME=pinned
APP_SERVER_NAME=pinned.example.test
APP_SOURCE=release
APP_RELEASE_REPOSITORY=demo/mnscloud-website
APP_REF=v2.0.0
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
build_json="$(curl -fsS "${base}/phoneweb/build.json")"
[[ "$build_json" == '{"product":"mnscloud-phoneweb","app":"phoneweb","version":"1.0.0","ref":"v1.0.0","minimumVersion":null}' ]] ||
  fail "build.json: $build_json"
pass "pinned release installed, verified, base href rewritten, SPA fallback, cache headers, build.json"

# --- root app (any domain) with "latest", next to the path-based app ----------------------------
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app website >/dev/null
[[ "$(readlink "${WORK}/root/current/website")" == */v2.0.0 ]] || fail "latest not resolved to v2.0.0"
for host in www.any-customer.test another-partner.example 127.0.0.1; do
  [[ "$(curl -fsS -H "Host: ${host}" "${base}/")" == *website-one* ]] || fail "website root for Host ${host}"
done
[[ "$(curl -fsS -H 'Host: any.test' "${base}/about/")" == *"about website-one"* ]] || fail "website subpage"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: any.test' "${base}/missing")" == "404" ]] || fail "website 404"
[[ "$(curl -sS -H 'Host: any.test' "${base}/missing")" == *"not found"* ]] || fail "website 404.html body"
curl -fsSI -H 'Host: any.test' "${base}/_astro/app.123.css" | grep -qi 'immutable' || fail "immutable cache"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: any.test' "${base}/.env")" == "404" ]] || fail "dotfile blocked"
[[ "$(curl -fsS -H 'Host: any.test' "${base}/phoneweb/")" == *phoneweb-one* ]] || fail "path app beside root app"
[[ "$(curl -fsS -H 'Host: any.test' "${base}/phoneweb/deep/route")" == *phoneweb-one* ]] || fail "SPA beside root app"
[[ "$(curl -fsS -H 'Host: any.test' "${base}/healthz")" == "ok" ]] || fail "healthz beside root app"
pass "root app answers any domain (root/subpages/404/immutable/dotfiles) beside path apps and healthz"

# --- optional host-pinned app --------------------------------------------------------------------
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app pinned >/dev/null
[[ "$(curl -fsS -H 'Host: pinned.example.test' "${base}/about/")" == *"about website-one"* ]] || fail "pinned host"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: pinned.example.test' "${base}/phoneweb/")" == "404" ]] || fail "pinned server must not serve path apps"
pass "host-pinned app answers only its own server_name"

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

# --- per-app state and the read-only status inventory -----------------------------------------
grep -q '"lastSyncStatus":"failed"' "${WORK}/root/state/tampered.json" || fail "failed install not recorded"
grep -q '"lastSyncStatus":"ok"' "${WORK}/root/state/website.json" || fail "ok install not recorded"
grep -q '"resolvedRef":"v2.0.0"' "${WORK}/root/state/website.json" || fail "resolved ref not recorded"
status_json="$(bash "${ROOT_DIR}/scripts/status-webapps.sh" --env "$ENV" --json)"
python3 - "$status_json" <<'PY' || fail "status-webapps.sh --json"
import json, sys
apps = {item["app"]: item for item in json.loads(sys.argv[1])}
assert apps["website"]["installedVersion"] == "v2.0.0" and apps["website"]["lastSyncStatus"] == "ok", apps["website"]
assert apps["phoneweb"]["basePath"] == "/phoneweb/" and apps["phoneweb"]["ref"] == "v1.0.0", apps["phoneweb"]
assert "tampered" not in apps, "disabled apps must not be listed"
PY
pass "per-app state recorded and status-webapps.sh --json reports installed/resolved/last sync"

# --- sync moves the pinned app forward after APP_REF=latest, prune + rollback ----------------
sed -i 's/^APP_REF=.*/APP_REF=latest/' "${WORK}/etc/apps.d/phoneweb.env"
sleep 1
bash "${ROOT_DIR}/scripts/sync-webapps.sh" --env "$ENV" >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-two* ]] || fail "sync did not install v1.1.0"
[[ "$(curl -fsS "${base}/phoneweb/build.json")" == *'"minimumVersion":"1.1.0"'* ]] ||
  fail "build.json must carry the release update-policy minimumVersion"
[[ -d "${WORK}/root/releases/phoneweb/v1.0.0" ]] || fail "previous release must be kept (active + KEEP=1)"
bash "${ROOT_DIR}/scripts/rollback-webapps.sh" --env "$ENV" --app phoneweb >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-one* ]] || fail "rollback did not restore v1.0.0"
[[ "$(curl -fsS "${base}/phoneweb/build.json")" == *'"version":"1.0.0"'* ]] || fail "build.json after rollback"
rm -f "${WORK}/root/releases/website/v2.0.0/build.json"
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app website >/dev/null
[[ "$(curl -fsS -H 'Host: any.test' "${base}/build.json")" == *'"product":"mnscloud-website"'* ]] ||
  fail "build.json not backfilled for an already active release"
pass "sync installs latest, rollback restores the previous release, build.json follows and is backfilled"

# --- deactivate stops serving an app but keeps its releases; reinstall serves it again -------
bash "${ROOT_DIR}/scripts/deactivate-webapp.sh" --env "$ENV" --app phoneweb >/dev/null
[[ ! -e "${WORK}/etc/nginx/apps/phoneweb.conf" && ! -L "${WORK}/root/current/phoneweb" ]] || fail "deactivate left phoneweb configured"
[[ "$(curl -sS -H 'Host: any.test' "${base}/phoneweb/")" != *phoneweb-* ]] || fail "deactivated app still served"
[[ -d "${WORK}/root/releases/phoneweb/v1.0.0" && -f "${WORK}/etc/apps.d/phoneweb.env" ]] || fail "deactivate removed releases or env"
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app phoneweb >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-* ]] || fail "reinstall after deactivate"
pass "deactivate-webapp.sh stops serving and keeps releases; reinstall serves again"

# --- catalog SHA-256 pin: wrong digest rejected (nothing changes), right digest installs ---------
v1_sha="$(sha256sum "${WORK}/gh/demo/mnscloud-phoneweb/releases/download/v1.0.0/mnscloud-phoneweb-web-v1.0.0.tar.gz" | awk '{ print $1 }')"
bad_sha="$(printf '%064d' 1)"
bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app phoneweb --ref v1.1.0 >/dev/null
before="$(readlink "${WORK}/root/current/phoneweb")"
if bash "${ROOT_DIR}/scripts/update-webapps.sh" --env "$ENV" --app phoneweb --app-ref v1.0.0 --app-sha256 "$bad_sha" >/dev/null 2>&1; then
  fail "catalog digest mismatch was accepted"
fi
[[ "$(readlink "${WORK}/root/current/phoneweb")" == "$before" ]] || fail "catalog mismatch changed the active release"
[[ ! -d "${WORK}/root/releases/phoneweb/v1.0.0" ]] || fail "mismatching cached release must be discarded"
if bash "${ROOT_DIR}/scripts/update-webapps.sh" --env "$ENV" --app phoneweb --app-sha256 "$v1_sha" >/dev/null 2>&1; then
  fail "--app-sha256 without --app-ref was accepted"
fi
bash "${ROOT_DIR}/scripts/update-webapps.sh" --env "$ENV" --app phoneweb --app-ref v1.0.0 --app-sha256 "$v1_sha" >/dev/null
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-one* ]] || fail "catalog-pinned v1.0.0 not served"
if bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app phoneweb --ref v1.0.0 --sha256 "$bad_sha" >/dev/null 2>&1; then
  fail "active release with a different catalog digest was accepted"
fi
[[ "$(curl -fsS "${base}/phoneweb/")" == *phoneweb-one* ]] || fail "active release changed after digest mismatch"
out="$(bash "${ROOT_DIR}/scripts/build-app.sh" --env "$ENV" --app phoneweb --ref v1.0.0 --sha256 "$v1_sha" 2>&1)"
[[ "$out" == *"already active"* ]] || fail "matching catalog digest should be a no-op: $out"
pass "catalog SHA-256 pin rejects mismatches without side effects and installs the catalog artifact"

# --- hosted tenant websites: verified snapshot per site, hosts, per-language 404, fallback -------
make_site() {
  local out="$1" marker="$2" extra="${3:-}"
  local src="${WORK}/site-src/${marker}"
  mkdir -p "$src/en" "$src/es" "$src/_astro"
  printf '<!doctype html><title>%s</title>%s home\n' "$marker" "$marker" > "$src/index.html"
  printf 'pt not found\n' > "$src/404.html"
  printf '%s en home\n' "$marker" > "$src/en/index.html"
  printf 'en not found\n' > "$src/en/404.html"
  printf 'es not found\n' > "$src/es/404.html"
  printf 'body{}\n' > "$src/_astro/site.1.css"
  case "$extra" in
    symlink) ln -s /etc/passwd "$src/leak" ;;
    noindex) rm -f "$src/index.html" ;;
  esac
  tar -C "$src" -czf "$out" .
}
SITE_ID="0123456789abcdef0123456789abcdef"
SITE_HOST="a1b2c3d4e5f6.dev.mnscloud.website"
make_site "${WORK}/site-v1.tar.gz" site-one
make_site "${WORK}/site-v2.tar.gz" site-two
make_site "${WORK}/site-bad.tar.gz" site-bad symlink
make_site "${WORK}/site-noindex.tar.gz" site-noindex noindex
sha() { sha256sum "$1" | awk '{ print $1 }'; }
site_install() {
  bash "${ROOT_DIR}/scripts/site-install.sh" --env "$ENV" --site "$SITE_ID" --version "$1" \
    --archive "$2" --sha256 "$3" --host "$SITE_HOST" --host www.customer-shop.test
}
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" "${base}/")" == "404" ]] || fail "site host without snapshot must be 404"
[[ "$(curl -sS -H "Host: ${SITE_HOST}" "${base}/")" == *"Site not found"* ]] || fail "site fallback body"
[[ "$(curl -fsS -H 'Host: any.test' "${base}/")" == *website-one* ]] || fail "root app beside the site fallback"
if site_install v1 "${WORK}/site-v1.tar.gz" "$(printf '%064d' 7)" >/dev/null 2>&1; then fail "site checksum mismatch accepted"; fi
if site_install v1 "${WORK}/site-bad.tar.gz" "$(sha "${WORK}/site-bad.tar.gz")" >/dev/null 2>&1; then fail "site archive with a symlink accepted"; fi
if site_install v1 "${WORK}/site-noindex.tar.gz" "$(sha "${WORK}/site-noindex.tar.gz")" >/dev/null 2>&1; then fail "site archive without index.html accepted"; fi
if bash "${ROOT_DIR}/scripts/site-install.sh" --env "$ENV" --site "$SITE_ID" --version v1 --archive "${WORK}/site-v1.tar.gz" \
  --sha256 "$(sha "${WORK}/site-v1.tar.gz")" --host 'evil.test;include /etc/x' >/dev/null 2>&1; then fail "invalid site host accepted"; fi
[[ ! -e "${WORK}/etc/nginx/sites/${SITE_ID}.conf" && ! -e "${WORK}/root/sites/${SITE_ID}/current" ]] || fail "rejected site installs must leave nothing served"
site_install v1 "${WORK}/site-v1.tar.gz" "$(sha "${WORK}/site-v1.tar.gz")" >/dev/null
for host in "$SITE_HOST" www.customer-shop.test; do
  [[ "$(curl -fsS -H "Host: ${host}" "${base}/")" == *"site-one home"* ]] || fail "site home for ${host}"
done
[[ "$(curl -fsS -H "Host: ${SITE_HOST}" "${base}/en/")" == *"site-one en home"* ]] || fail "site /en/"
[[ "$(curl -sS -H "Host: ${SITE_HOST}" "${base}/en/missing")" == *"en not found"* ]] || fail "site /en/ 404 page"
[[ "$(curl -sS -H "Host: ${SITE_HOST}" "${base}/es/missing")" == *"es not found"* ]] || fail "site /es/ 404 page"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" "${base}/missing")" == "404" ]] || fail "site 404 status"
[[ "$(curl -sS -H "Host: ${SITE_HOST}" "${base}/missing")" == *"pt not found"* ]] || fail "site root 404 page"
curl -fsSI -H "Host: ${SITE_HOST}" "${base}/_astro/site.1.css" | grep -qi 'immutable' || fail "site immutable assets"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" "${base}/.env")" == "404" ]] || fail "site dotfiles blocked"
[[ "$(curl -fsS -H "Host: www.customer-shop.test" "${base}/phoneweb/")" == *phoneweb-* ]] || fail "custom site host must keep the path apps"
[[ -f "${WORK}/etc/nginx/apps-root/website.conf" && ! -e "${WORK}/etc/nginx/apps/website.conf" ]] || fail "root app conf must live in nginx/apps-root"
[[ "$(curl -sS -H 'Host: other1234.dev.mnscloud.website' "${base}/")" == *"Site not found"* ]] || fail "another site host must hit the fallback"
site_install v2 "${WORK}/site-v2.tar.gz" "$(sha "${WORK}/site-v2.tar.gz")" >/dev/null
[[ "$(curl -fsS -H "Host: ${SITE_HOST}" "${base}/")" == *"site-two home"* ]] || fail "site v2 not served"
[[ -d "${WORK}/root/sites/${SITE_ID}/releases/v1" ]] || fail "previous site release must be kept"
site_install v3 "${WORK}/site-v1.tar.gz" "$(sha "${WORK}/site-v1.tar.gz")" >/dev/null
[[ ! -d "${WORK}/root/sites/${SITE_ID}/releases/v1" && -d "${WORK}/root/sites/${SITE_ID}/releases/v2" ]] || fail "site releases not pruned to active + 1"
grep -q '"version":"v3"' "${WORK}/root/sites/${SITE_ID}/state.json" || fail "site state not recorded"
# Runtimes rendered before nginx/apps-root kept the root app in nginx/apps/: the next render moves it.
mv "${WORK}/etc/nginx/apps-root/website.conf" "${WORK}/etc/nginx/apps/website.conf"
bash "${ROOT_DIR}/scripts/validate-webapps.sh" --env "$ENV" >/dev/null || fail "validate after the legacy root app layout"
[[ -f "${WORK}/etc/nginx/apps-root/website.conf" && ! -e "${WORK}/etc/nginx/apps/website.conf" ]] || fail "legacy root app conf not moved"
bash "${ROOT_DIR}/scripts/site-remove.sh" --env "$ENV" --site "$SITE_ID" >/dev/null
[[ "$(curl -sS -H "Host: ${SITE_HOST}" "${base}/")" == *"Site not found"* ]] || fail "removed site still served"
[[ "$(curl -sS -H 'Host: www.customer-shop.test' "${base}/")" == *website-one* ]] || fail "custom host returns to the root app after removal"
[[ ! -e "${WORK}/root/sites/${SITE_ID}" ]] || fail "site releases not deleted"
bash "${ROOT_DIR}/scripts/site-remove.sh" --env "$ENV" --site "$SITE_ID" >/dev/null || fail "removing a missing site must succeed"
pass "hosted websites: verified snapshots, hosts, path apps on custom hosts, per-language 404, fallback, atomic swap, prune, removal"

bash "${ROOT_DIR}/scripts/validate-webapps.sh" --env "$ENV" >/dev/null || fail "validate-webapps.sh"
pass "validate-webapps.sh passes for all enabled apps"

printf '[smoke] all checks passed\n'
