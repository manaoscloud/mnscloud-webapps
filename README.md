# mnscloud-webapps

Runtime that serves the final static builds of small MNSCloud web clients such as PhoneWeb, Pulse,
the public website, and future lightweight modules.

This module is not the public edge. Public HTTP/S, TLS, rate limiting, and external routing are
owned by `mnscloud-nginx`. WebApps listens on a private host/port and serves static bundles that the
edge proxies either under paths such as `/phoneweb/` and `/pulse/` or, for host-based apps such as
the website, at the root of their own domain.

## Contract

- Product/runtime: `mnscloud-webapps`
- Project directory: `/opt/mnscloud/mnscloud-webapps`
- Runtime root: `/opt/mnscloud/webapps`
- Runtime env: `/etc/mnscloud/webapps/webapps.env`
- Per-app env directory: `/etc/mnscloud/webapps/apps.d`
- Internal service: `mnscloud-webapps.service`
- Optional artifact sync: `mnscloud-webapps-sync.timer` (`WEBAPPS_AUTO_SYNC=true`)
- Internal health endpoint: `/healthz`
- Default listen address: `127.0.0.1:8080`
- Shared runtime kit: `/opt/mnscloud/runtime-kit`

## Security Boundary

Every web bundle served here is public browser code. Do not place secrets, production internal
addresses, customer data, PABX credentials, tenant policy, payroll rules, or provider credentials in
app env files or builds.

App env files may contain only public-safe values:

- app name, public base path or public host names;
- release repository and release tag (or source repository and ref);
- public API path such as `/api/v1`;
- public feature flags.

Authorization, employee scope, PABX queue ownership, and secret resolution stay in the MNSCloud API.

## App Sources

Each `apps.d/<app>.env` selects how the bundle is obtained:

| `APP_SOURCE` | What happens | Host requirements |
| --- | --- | --- |
| `release` (recommended) | Downloads `<repo>-web-v<version>.tar.gz` and its `.sha256` from the GitHub Release `APP_REF` (`latest` or a tag such as `v0.1.57`) of `APP_RELEASE_REPOSITORY`, verifies the checksum, rejects unsafe archive paths, rewrites `<base href="/">` to `APP_BASE_PATH`, and activates it. | `curl`, `tar`, `sha256sum` only. No Flutter or Node.js. |
| `build` (default for older env files) | Clones `APP_REPO_URL` at `APP_REF` and runs `APP_BUILD_COMMAND` (Flutter) on the host. | Flutter SDK, several GB of disk, enough RAM for `flutter build web`. |

Release artifacts are produced by each client repository's release workflow through
`mnscloud-runtime-kit` `scripts/package-static-artifact.sh`. Releases are stored as
`releases/<app>/<tag>` (or a timestamp for source builds) with a `<tag>.json` record of the
repository, asset, and SHA-256. `current/<app>` points at the active release. Besides the active
release, the newest `WEBAPPS_KEEP_RELEASES` previous releases are kept for rollback.

### Path-based and host-based apps

- Path-based (default): served under `APP_BASE_PATH` (for example `/phoneweb/`) on the default
  server, with single-page-app fallback to `index.html`.
- Host-based: set `APP_SERVER_NAME` (space-separated host names). The app gets its own `server`
  block at `/`, serving static files with `404.html` fallback. Use this for the website
  (`config/apps.d/website.env.example`); the edge must forward the original `Host` header.
- `APP_IMMUTABLE_PATHS` (for example `/_astro/`) marks fingerprinted asset prefixes for
  long-lived immutable caching. Everything else is served with `Cache-Control: no-cache`, so
  browsers revalidate and pick up new releases.

## Install

Supported bare-metal operating systems:

- Debian 12/13
- RHEL 9/10
- Rocky Linux 9/10
- AlmaLinux 9/10

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
git clone https://github.com/manaoscloud/mnscloud-webapps.git
cd /opt/mnscloud/mnscloud-webapps
git checkout "$(git tag -l 'v*' --sort=-v:refname | head -n1)"
sudo ./scripts/install-webapps.sh --env /etc/mnscloud/webapps/webapps.env
```

The installer uses `mnscloud-runtime-kit` to configure the official stable `nginx.org` package
repository when Nginx is missing and installs `nginx` from it, disables the default
`nginx.service`, and starts the isolated `mnscloud-webapps.service` using its own runtime config.
It then refreshes the local `mnscloud-agent` capabilities so the control plane can update this
runtime (`mnscloud.webapps.update`).

Flutter is installed only when needed: with the default `WEBAPPS_INSTALL_FLUTTER=auto` it is
installed when an enabled app uses `APP_SOURCE=build`. Use `true` to always install it or `false`
to never install it. Flutter tooling and source builds run as the `WEBAPPS_FLUTTER_RUN_USER` service
user.

For production, pin the runtime kit by ref in `/etc/mnscloud/webapps/webapps.env`:

```env
WEBAPPS_RUNTIME_KIT_CHANNEL=stable
WEBAPPS_RUNTIME_KIT_REF=
```

Use `main` only for development environments.

When the edge runs on another host, listen on the private address and allow only the edge:

```env
WEBAPPS_LISTEN_HOST=<private-ip-of-this-host>
WEBAPPS_LISTEN_PORT=8080
WEBAPPS_ALLOWED_CLIENTS=<private-ip-of-the-edge>
```

`WEBAPPS_ALLOWED_CLIENTS` renders nginx `allow`/`deny` rules (loopback and the listen address are
always allowed). Keep the host firewall closed to everything else as well.

Review app env files before installing apps:

```bash
sudo editor /etc/mnscloud/webapps/apps.d/phoneweb.env
sudo editor /etc/mnscloud/webapps/apps.d/pulse.env
```

## Update

The control plane updates this runtime through `mnscloud-agent` (`runtime.update` for product
`mnscloud-webapps`): the Agent checks out the release tag and runs `scripts/update-webapps.sh`,
which re-renders the service units and runtime config and then installs every enabled app.

Manual equivalents:

```bash
sudo ./scripts/update-latest-webapps.sh --env /etc/mnscloud/webapps/webapps.env
sudo ./scripts/update-webapps.sh --env /etc/mnscloud/webapps/webapps.env --app phoneweb
sudo ./scripts/update-webapps.sh --env /etc/mnscloud/webapps/webapps.env --app pulse --app-ref v1.0.2
```

`update-latest-webapps.sh` resolves the approved runtime release from the control-plane registry
when `WEBAPPS_RELEASE_API_BASE_URL` (or `--api-base`) is set and otherwise uses the latest Git tag.

### Automatic app sync

With `WEBAPPS_AUTO_SYNC=true`, `mnscloud-webapps-sync.timer` runs `scripts/sync-webapps.sh` every
`WEBAPPS_AUTO_SYNC_INTERVAL` (default `15min`). It converges each enabled `APP_SOURCE=release` app to
its `APP_REF` and leaves apps already at the resolved release untouched. Use it with
`APP_REF=latest` in development so new client releases go live without a runtime release. Keep it
disabled, or pin `APP_REF` to tags, where promotions must stay manual.

All mutating scripts share a lock, so the timer never overlaps an Agent update or a rollback.

## Validate

```bash
sudo ./scripts/validate-webapps.sh --env /etc/mnscloud/webapps/webapps.env
curl -fsS http://127.0.0.1:8080/healthz
```

Validation renders and tests the nginx config, checks the service, and requests every enabled app
(path-based apps by path, host-based apps with their `Host` header), printing the active release of
each.

Validate through the edge after enabling the `mnscloud-nginx` webapps proxy:

```bash
curl -I https://app.example.com/pulse/
curl -I https://app.example.com/phoneweb/
curl -I https://app.example.com/api/v1/health
```

## Rollback

Rollback to the previous release (newest installed release other than the active one):

```bash
sudo ./scripts/rollback-webapps.sh --app pulse
```

Rollback to a specific release id (a tag for release artifacts, a timestamp for source builds):

```bash
sudo ./scripts/rollback-webapps.sh --app phoneweb --release v0.1.56
```

With `WEBAPPS_AUTO_SYNC=true` and `APP_REF=latest`, pin `APP_REF` to the rolled-back tag, or the
next sync moves the app forward again.

Rollback of the runtime itself is a runtime update to an older tag (`scripts/update-webapps.sh --ref
vX.Y.Z`).

## Nginx Edge

Expose path-based apps through `mnscloud-nginx`:

```env
MNSCLOUD_ENABLE_WEBAPPS_PROXY=true
MNSCLOUD_WEBAPPS_UPSTREAM=http://<webapps-private-ip>:8080
MNSCLOUD_PHONEWEB_PATH=/phoneweb/
MNSCLOUD_PULSE_PATH=/pulse/
```

Expose the host-based website by pointing the edge website upstream at the same listener:

```env
MNSCLOUD_WEBSITE_DOMAIN=www.example.com
MNSCLOUD_WEBSITE_UPSTREAM=http://<webapps-private-ip>:8080
```

The public API used by these clients should normally be `/api/v1`, letting the edge proxy API calls
to `mnscloud-api`.
