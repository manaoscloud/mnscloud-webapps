# AGENTS.md

MNSCloud WebApps is the runtime that installs and serves final static builds of small public web
clients such as PhoneWeb, Pulse, the public website, and future lightweight modules. Bundles normally
come from verified GitHub Release artifacts (`APP_SOURCE=release`).

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

## Boundaries

- Do not commit secrets, customer data, production IPs/domains, provider credentials, internal
  topology, or tenant-specific policy.
- Public clients receive only public-safe configuration such as base path, public API path, feature
  flags, and build references.
- Sensitive authorization, employee scope, PABX queue ownership, payroll rules, and secret
  resolution stay in the MNSCloud API/control plane.
- The public edge is owned by `mnscloud-nginx`; this module serves HTTP privately.

## Lifecycle

- Install: `scripts/install-webapps.sh`
- Update/build: `scripts/update-webapps.sh` (Agent `runtime.update`, product `mnscloud-webapps`)
- Release artifact sync: `scripts/sync-webapps.sh` (`mnscloud-webapps-sync.timer`)
- Validate: `scripts/validate-webapps.sh`
- Rollback: `scripts/rollback-webapps.sh`

Validate with `bash -n scripts/*.sh scripts/lib/*.sh` and `bash tests/runtime-smoke.sh`. After
completed changes, validate, commit, and push to GitHub.
