# Topology

Recommended production layout:

```text
public internet
  -> mnscloud-nginx (TLS, rate limiting, public domains)
       -> /api/        -> mnscloud-api
       -> /            -> mnscloud-app
       -> /phoneweb/   -> mnscloud-webapps (path-based app)
       -> /pulse/      -> mnscloud-webapps (path-based app)
       -> website host -> mnscloud-webapps (host-based app, original Host header)
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
