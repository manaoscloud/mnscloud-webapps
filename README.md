# mnscloud-webapps

Private runtime for final static builds of small MNSCloud web clients such as PhoneWeb, Pulse, and
future lightweight modules.

This module is not the public edge. Public HTTP/S, TLS, rate limiting, and external routing are
owned by `mnscloud-nginx`. WebApps listens on a private host/port and serves static bundles that the
edge proxies under paths such as `/phoneweb/` and `/pulse/`.

## Contract

- Product/runtime: `mnscloud-webapps`
- Project directory: `/opt/mnscloud/mnscloud-webapps`
- Runtime root: `/opt/mnscloud/webapps`
- Runtime env: `/etc/mnscloud/webapps/webapps.env`
- Per-app env directory: `/etc/mnscloud/webapps/apps.d`
- Internal service: `mnscloud-webapps.service`
- Internal health endpoint: `/healthz`
- Default listen address: `127.0.0.1:8080`
- Shared runtime kit: `/opt/mnscloud/runtime-kit`

## Security Boundary

Every web bundle produced here is public browser code. Do not place secrets, production internal
addresses, customer data, PABX credentials, tenant policy, payroll rules, or provider credentials in
app env files or builds.

App env files may contain only public-safe values:

- app name and public base path;
- repository URL and release ref;
- public API path such as `/api/v1`;
- public feature flags.

Authorization, employee scope, PABX queue ownership, and secret resolution stay in the MNSCloud API.

## Install

Supported bare-metal operating systems:

- Debian 12/13
- RHEL 9/10
- Rocky Linux 9/10
- AlmaLinux 9/10

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-webapps
cd /opt/mnscloud/mnscloud-webapps
sudo ./scripts/install-webapps.sh --env /etc/mnscloud/webapps/webapps.env
```

The installer uses `mnscloud-runtime-kit` to configure the official stable `nginx.org` package
repository when Nginx is missing, install `nginx` from that repository, and install the Flutter/Dart
SDK from the official Flutter GitHub repository with the OS build dependencies needed for web
builds. Then it disables the default `nginx.service` and starts the isolated
`mnscloud-webapps.service` using its own runtime config.

For production, pin the runtime kit by ref in `/etc/mnscloud/webapps/webapps.env`:

```env
WEBAPPS_RUNTIME_KIT_REF=v0.1.2
```

Use `main` only for development environments.

The default Flutter dependency profile is `WEBAPPS_FLUTTER_BUILD_PROFILE=web`, which is enough for
final static web builds. Use `linux` only on hosts that also need Flutter Linux desktop builds.
Flutter tooling and web builds run as the `WEBAPPS_FLUTTER_RUN_USER` service user.

Review app env files before building:

```bash
sudo editor /etc/mnscloud/webapps/apps.d/phoneweb.env
sudo editor /etc/mnscloud/webapps/apps.d/pulse.env
```

## Update

Build one app:

```bash
sudo ./scripts/update-webapps.sh --app pulse --ref main
sudo ./scripts/update-webapps.sh --app phoneweb --ref main
```

Build all apps listed in `WEBAPPS_ENABLED_APPS`:

```bash
sudo ./scripts/update-webapps.sh
```

## Validate

```bash
sudo ./scripts/validate-webapps.sh --env /etc/mnscloud/webapps/webapps.env
curl -fsS http://127.0.0.1:8080/healthz
curl -I http://127.0.0.1:8080/pulse/
curl -I http://127.0.0.1:8080/phoneweb/
```

Validate through the edge after enabling the `mnscloud-nginx` webapps proxy:

```bash
curl -I https://app.example.com/pulse/
curl -I https://app.example.com/phoneweb/
curl -I https://app.example.com/api/v1/health
```

## Rollback

Rollback to the previous release:

```bash
sudo ./scripts/rollback-webapps.sh --app pulse
```

Rollback to a specific release id:

```bash
sudo ./scripts/rollback-webapps.sh --app phoneweb --release 20260530120000
```

## Nginx Edge

Expose this runtime through `mnscloud-nginx`:

```env
MNSCLOUD_ENABLE_WEBAPPS_PROXY=true
MNSCLOUD_WEBAPPS_UPSTREAM=http://127.0.0.1:8080
MNSCLOUD_PHONEWEB_PATH=/phoneweb/
MNSCLOUD_PULSE_PATH=/pulse/
```

The public API used by these clients should normally be `/api/v1`, letting the edge proxy API calls
to `mnscloud-api`.
