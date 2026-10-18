# Topology

Recommended production layout:

```text
public internet
  -> mnscloud-nginx (TLS, rate limiting, public domains)
       -> /api/        -> mnscloud-api
       -> /            -> mnscloud-app
       -> /phoneweb/   -> mnscloud-webapps (path-based app)
       -> /pulse/      -> mnscloud-webapps (path-based app)
       -> /pos/        -> mnscloud-webapps (path-based app, online-only POS)
       -> any website domain -> mnscloud-webapps (root app, answers any Host)
```

`mnscloud-webapps` listens privately. Restrict its listen port to the edge with
`WEBAPPS_ALLOWED_CLIENTS` and the host firewall.

Bundles come from GitHub Releases of each client repository (`APP_SOURCE=release`), so the
webapps host only downloads, verifies, and serves static files:

```text
client repo release workflow
  -> builds the static bundle and uploads <repo>-web-v<version>.tar.gz + .sha256
mnscloud-webapps (Agent runtime update or sync timer)
  -> downloads, verifies SHA-256, extracts releases/<app>/<tag>, switches current/<app>
```

## Release build metadata (`build.json`)

Activating a release tag `vX.Y.Z` (install, sync, update or rollback) writes `build.json` at the
root of that release, served under the app's base path (for example `/phoneweb/build.json`):

```json
{"product":"mnscloud-phoneweb","app":"phoneweb","version":"0.1.58","ref":"v0.1.58","minimumVersion":null}
```

`minimumVersion` comes from `update-policy.json` at the root of the release bundle, declared by the
client repository for a critical fix; tabs running a lower version get a notice they cannot
postpone. It is `null` when the bundle has no policy or the value is not a version.

Open browser tabs poll it (with `cache: no-store`) and compare `version` with the version compiled
into their bundle to show a "new version available" notice without a page refresh. It holds no
secrets or topology. Releases already active before this file existed get it on the next sync.
