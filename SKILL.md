# MNSCloud WebApps Skill

Use this repository for the private runtime that builds and serves final static web bundles for
small MNSCloud clients.

## Rules

- Treat every app bundle as public browser code.
- Keep secrets and private infrastructure details out of app env files and build artifacts.
- Use `/etc/mnscloud/webapps/apps.d/<app>.env` for public-safe per-app settings.
- Keep public exposure in `mnscloud-nginx`; this module listens on a private host/port.
- Use `mnscloud-runtime-kit` for shared runtime installation logic such as Nginx and Flutter.
- Run lifecycle validation after installer, runtime, or config changes.

## Validation

```bash
bash -n scripts/*.sh scripts/lib/*.sh
sudo ./scripts/validate-webapps.sh --env /etc/mnscloud/webapps/webapps.env
```
