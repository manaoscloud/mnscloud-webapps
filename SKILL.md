# MNSCloud WebApps Skill

Use this repository for the runtime that installs and serves final static web bundles for small
MNSCloud clients (PhoneWeb, Pulse, the public website, and future lightweight modules).

## Operating model (read before changing hosts or clients)

This runtime is not deployed like the API or App. Web clients (PhoneWeb, Pulse, POS, customer
portal, website) are **apps of this runtime**, installed from their public GitHub Release bundles
(`APP_SOURCE=release`: no build and no secret on the host). A client is public only when three layers
agree: the app is enabled here (`WEBAPPS_ENABLED_APPS` + `apps.d/<app>.env`), the edge publishes its
path (`mnscloud-nginx` `nginx.env`, resource `nginx.webapps`) and the ThemeDomain vhosts were
re-rendered by the Agent. Move one client with a single-app job
(`mnscloud-webapps:<app>[@vX.Y.Z]`); DEV auto-syncs `APP_REF=latest`, production changes only by an
explicit single-app rollout carrying the catalog SHA-256. The listener accepts only the edge, so
verify through the public domains by page title and `<base href>`. Workspace contract:
`docs/webapps.md` in the MNSCloud workspace.

## Rules

- Treat every app bundle as public browser code.
- Keep secrets and private infrastructure details out of app env files and build artifacts.
- Use `/etc/mnscloud/webapps/apps.d/<app>.env` for public-safe per-app settings.
- Keep public exposure in `mnscloud-nginx`; this module listens on a private host/port.
- Use `mnscloud-runtime-kit` for shared runtime installation logic such as Nginx and Flutter.
- Prefer `APP_SOURCE=release`: install the verified prebuilt artifact published with the client
  release (`<repo>-web-v<version>.tar.gz` + `.sha256`). Keep `APP_SOURCE=build` only for builds
  that need host-specific `--dart-define` values; it requires Flutter on the host.
- Never skip checksum verification or the archive path checks when installing artifacts.
- The website is white-label: serve it as the root app (`APP_BASE_PATH=/`, `APP_ROUTING=static`) so
  it answers any domain; never require a fixed domain in webapps. Path apps use `APP_BASE_PATH`;
  `APP_SERVER_NAME` is optional host pinning. Keep path, root and host-based modes working when
  changing nginx rendering.
- Restrict the listener with `WEBAPPS_ALLOWED_CLIENTS` when it is not bound to loopback.
- Do not hardcode MNSCloud domains or private addresses in scripts, examples, or docs; use
  placeholders and env settings.
- Run lifecycle validation after installer, runtime, or config changes.

## Validation

```bash
bash -n scripts/*.sh scripts/lib/*.sh
bash tests/runtime-smoke.sh
sudo ./scripts/validate-webapps.sh --env /etc/mnscloud/webapps/webapps.env
```
