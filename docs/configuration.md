# Configuration

Runtime configuration lives in `/etc/mnscloud/webapps/webapps.env`.

The installer uses the host package manager to install `nginx` when missing. The default
`nginx.service` is stopped and disabled so only `mnscloud-webapps.service` owns the private runtime
listener.

Per-app public-safe configuration lives in:

```text
/etc/mnscloud/webapps/apps.d/phoneweb.env
/etc/mnscloud/webapps/apps.d/pulse.env
```

Each app must define:

- `APP_NAME`
- `APP_REPO_URL`
- `APP_REF`
- `APP_BASE_PATH`
- `APP_PUBLIC_API_BASE_URL`
- `APP_BUILD_COMMAND`

Use same-origin API paths when the app is published through `mnscloud-nginx`:

```env
APP_PUBLIC_API_BASE_URL=/api/v1
```

Do not use private API upstreams such as `http://10.x.x.x:8000/api/v1` in public app builds.
