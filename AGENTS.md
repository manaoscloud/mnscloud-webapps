# AGENTS.md

MNSCloud WebApps is the runtime that installs and serves final static builds of small public web
clients such as PhoneWeb, Pulse, the public website, and future lightweight modules. Bundles normally
come from verified GitHub Release artifacts (`APP_SOURCE=release`).

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
