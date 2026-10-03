# Configuration

Runtime configuration lives in `/etc/mnscloud/webapps/webapps.env` (see
`config/webapps.env.example`).

The installer configures the official stable `nginx.org` package repository and installs `nginx`
from that repository when Nginx is missing. Supported operating systems follow the edge gateway
contract: Debian 12/13 and RHEL/Rocky/AlmaLinux 9/10. The default `nginx.service` is stopped and
disabled so only `mnscloud-webapps.service` owns the private runtime listener.

## Runtime settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEBAPPS_LISTEN_HOST` / `WEBAPPS_LISTEN_PORT` | `127.0.0.1` / `8080` | Private listener. Use the host's private address when the edge runs elsewhere. |
| `WEBAPPS_ALLOWED_CLIENTS` | empty | Comma-separated IPs/CIDRs allowed to connect (nginx `allow`/`deny`). Loopback and the listen address are always allowed. Empty disables the allowlist. |
| `WEBAPPS_ENABLED_APPS` | `phoneweb,pulse` | Apps installed by `update-webapps.sh`/`sync-webapps.sh` when `--app` is not given. |
| `WEBAPPS_INSTALL_FLUTTER` | `auto` | `auto` installs Flutter only when an enabled app uses `APP_SOURCE=build`; `true`/`false` force it. |
| `WEBAPPS_KEEP_RELEASES` | `5` | Previous release directories kept per app for rollback, in addition to the active one. |
| `WEBAPPS_AUTO_SYNC` / `WEBAPPS_AUTO_SYNC_INTERVAL` | `false` / `15min` | Enables `mnscloud-webapps-sync.timer`, which converges `APP_SOURCE=release` apps to `APP_REF`. |
| `WEBAPPS_GITHUB_BASE_URL` | `https://github.com` | Base URL for release downloads and `latest` resolution (GitHub Enterprise or a mirror with the same layout). |
| `WEBAPPS_RELEASE_API_BASE_URL` | empty | Optional control-plane URL used by `update-latest-webapps.sh`; empty uses the latest Git tag. |

Flutter settings (`WEBAPPS_FLUTTER_DIR`, `WEBAPPS_FLUTTER_CHANNEL`, `WEBAPPS_FLUTTER_BUILD_PROFILE`,
`WEBAPPS_FLUTTER_RUN_USER`, `WEBAPPS_FLUTTER_HOME`) only matter for `APP_SOURCE=build` apps.

## Per-app settings

Per-app public-safe configuration lives in `/etc/mnscloud/webapps/apps.d/<app>.env`. The installer
copies `config/apps.d/*.env.example` once and never overwrites existing files.

| Variable | Applies to | Purpose |
| --- | --- | --- |
| `APP_NAME` | all | Must match the file name. |
| `APP_SOURCE` | all | `release` (prebuilt GitHub Release artifact) or `build` (Flutter source build). Defaults to `build` for older env files. |
| `APP_BASE_PATH` | path/root | Public path such as `/phoneweb/`; `/` makes it the root app of the default server, answering any `Host` (one per runtime). Release bundles get `<base href>` rewritten to it. |
| `APP_ROUTING` | all | `spa` (fallback to `index.html`; default for path/root apps) or `static` (files, `$uri.html`, `404.html`; default for host-based apps). |
| `APP_SERVER_NAME` | host-based | Optional space-separated host names; serves the app at `/` in its own server block that answers only those names. |
| `APP_IMMUTABLE_PATHS` | all | Fingerprinted asset prefixes (for example `/_astro/`) cached as immutable. |
| `APP_RELEASE_REPOSITORY` | `release` | `<owner>/<repo>` publishing the artifact. |
| `APP_RELEASE_ASSET_PREFIX` | `release` | Asset prefix; default `<repo>-web-v`, giving `<repo>-web-v<version>.tar.gz`. |
| `APP_REF` | all | `release`: `latest` or a tag such as `v1.2.3`. `build`: Git ref (default `main`). |
| `APP_REPO_URL`, `APP_BUILD_COMMAND` | `build` | Source repository and build command. |
| `APP_PUBLIC_API_BASE_URL` | `build` | Public API base passed to the build command. |

Use same-origin API paths when the app is published through `mnscloud-nginx`:

```env
APP_PUBLIC_API_BASE_URL=/api/v1
```

Do not use private API upstreams such as `http://10.x.x.x:8000/api/v1` in public app builds.
