# AGENTS.md

MNSCloud WebApps is the private runtime for final static builds of small public web clients such as
PhoneWeb, Pulse, and future lightweight modules.

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
- Update/build: `scripts/update-webapps.sh`
- Validate: `scripts/validate-webapps.sh`
- Rollback: `scripts/rollback-webapps.sh`

After completed changes, validate, commit, and push to GitHub.
