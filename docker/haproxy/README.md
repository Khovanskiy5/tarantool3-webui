# HAProxy configurations

- `haproxy.dev.cfg` — local development. Plain HTTP on 8080, stats on 8404, three Tarantool instances behind `webui_be`.
- `haproxy.prod.example.cfg` — production starting point (Task 11). TLS termination on 443, mTLS option, opt-in `keepalived` companion for HA of the balancer itself.

## What stays the same between dev and prod

| Concern | Choice |
|---|---|
| Healthcheck endpoint | `GET /api/health` |
| Healthcheck verdict | `200` ⇒ in rotation (covers both `ok` and `degraded`), `503` ⇒ out of rotation |
| Sticky session | Cookie `SRVID` on `/ws` and `/admin/api` paths only |
| Round-robin elsewhere | Static `/assets/*` and `/index.html` stay balanced |
| Timeouts | 1h on client/server/tunnel for WebSocket |

## What differs between dev and prod

| Concern | dev | prod |
|---|---|---|
| Listener | `bind *:8080` (HTTP) | `bind *:443 ssl crt …` (HTTPS) |
| Stats UI access | open on 8404 inside compose network | bound to private subnet |
| Logging destination | stdout | syslog/Vector/ELK |
| HA of HAProxy itself | single instance | optional keepalived / VRRP pair |
| External etcd | local compose service | separate cluster |

## Verifying behaviour

After `make dev`:

```bash
# Health
curl -i http://localhost:8080/api/health

# Stats UI in browser
open http://localhost:8404/

# Verify sticky cookie issued on /admin/api
curl -i -X POST http://localhost:8080/admin/api \
    -H 'content-type: application/json' \
    -d '{"query":"{ ping }"}'    # response carries Set-Cookie: SRVID=tt-N

# Verify failover: stop one instance and reissue requests
docker compose stop tt-1
curl http://localhost:8080/api/health   # still 200 — HAProxy now talks to tt-2 or tt-3
```
