# MNSCloud WebApps Skill

Use this repository for the runtime that installs and serves final static web bundles for small
MNSCloud clients (PhoneWeb, Pulse, the public website, and future lightweight modules).

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
- Host-based apps (`APP_SERVER_NAME`) serve a site at `/` of its own domain; path-based apps use
  `APP_BASE_PATH`. Keep both modes working when changing nginx rendering.
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
