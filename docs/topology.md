# Topology

Recommended production layout:

```text
public internet
  -> mnscloud-nginx
       -> /api/      -> mnscloud-api
       -> /          -> mnscloud-app
       -> /phoneweb/ -> mnscloud-webapps
       -> /pulse/    -> mnscloud-webapps
```

`mnscloud-webapps` listens privately. Firewall rules should prevent direct public access to its
listen port.
