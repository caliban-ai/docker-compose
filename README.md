# caliban-ai/docker-compose

Docker Compose stack for self-hosting the **caliban-ai** suite on a single host:

| Service | Role | Image |
|---|---|---|
| [**caliban**](https://github.com/caliban-ai/caliban) | per-workspace agent supervisor (`caliband`) | `ghcr.io/caliban-ai/caliban` |
| [**gonzalo**](https://github.com/caliban-ai/gonzalo) | persistence / code-graph MCP server | `ghcr.io/caliban-ai/gonzalo` |
| [**prospero**](https://github.com/caliban-ai/prospero) | fleet dashboard / control plane | `ghcr.io/caliban-ai/prospero` |

It pulls pinned, published images from GHCR, ships production-safe defaults, and
persists state in named volumes. For Kubernetes, use
[`caliban-ai/helm-charts`](https://github.com/caliban-ai/helm-charts) instead.

> **Prerequisite:** the `ghcr.io/caliban-ai/caliban` image must be published
> before the `caliban` service can pull. gonzalo and prospero images are already
> on GHCR. Set `CALIBAN_VERSION` in `.env` to the first published caliban release.

## Quick start

```sh
git clone https://github.com/caliban-ai/docker-compose
cd docker-compose

cp .env.example .env          # then edit: set ANTHROPIC_API_KEY
mkdir -p workspace            # the repo/workspace caliban will supervise
./scripts/preflight.sh        # optional sanity check

docker compose up -d
open http://localhost:7878    # prospero dashboard
```

The base stack runs all three services with SQLite persistence and wires
prospero ↔ caliban over a shared Unix control socket — no TLS, no reverse proxy.

## How it fits together

- **caliban** runs `caliband`, the per-workspace supervisor. It supervises the
  directory you mount at `/workspace` (`CALIBAN_WORKSPACE`, default `./workspace`)
  and derives its control-socket name from that path.
- **prospero** discovers caliban's socket in the shared `caliban-runtime` volume.
  Because the socket name is a hash of the *canonical* workspace path, the
  workspace is mounted at the **same path (`/workspace`) in both containers** so
  the hashes match. prospero runs with `--no-autostart` (caliban is its own
  service, not spawned by prospero).
- **gonzalo** is reachable on the compose network at `http://gonzalo:8080`
  (HTTP/MCP) and `gonzalo:50051` (gRPC). To give caliban gonzalo's code-graph
  tools, reference it from your workspace's `.mcp.json`.

### Using a subset

Name the services you want:

```sh
docker compose up -d gonzalo caliban      # no dashboard
docker compose up -d gonzalo              # persistence only
```

## Configuration

All configuration is in `.env` (copied from `.env.example`, gitignored). Key knobs:

| Var | Purpose | Default |
|---|---|---|
| `CALIBAN_VERSION` / `GONZALO_VERSION` / `PROSPERO_VERSION` | pinned image tags | see `.env.example` |
| `ANTHROPIC_API_KEY` | caliban model credential (default provider) | — |
| `PROSPERO_HTTP_PORT` | host port for the dashboard | `7878` |
| `CALIBAN_WORKSPACE` | host dir caliban supervises | `./workspace` |
| `RUST_LOG` | log verbosity | `info` |

Pin images by digest (`0.1.0@sha256:…`) for fully reproducible deploys.

## Overlays (variants)

Stack overlay files with additional `-f` flags. Combine freely (except where noted).

### Postgres — `overlays/postgres.yaml`

Run prospero against Postgres instead of SQLite. Set `POSTGRES_*` in `.env`.

```sh
docker compose -f compose.yaml -f overlays/postgres.yaml up -d
```

### Reverse-proxy / HTTPS — `overlays/proxy.yaml`

Put Caddy in front of the dashboard on :80/:443 with automatic TLS. Set `DOMAIN`
in `.env` (a real DNS name in production; `*.localhost` for local testing). The
raw `:7878` port is no longer published — reach the dashboard via `https://$DOMAIN`.

```sh
docker compose -f compose.yaml -f overlays/proxy.yaml up -d
```

### Secrets — `overlays/secrets.yaml`

Supply credentials as docker secrets (files) instead of `.env` env vars.

```sh
printf %s 'sk-ant-...' > secrets/anthropic_api_key && chmod 600 secrets/anthropic_api_key
docker compose -f compose.yaml -f overlays/secrets.yaml up -d
```

See [`secrets/README.md`](secrets/README.md).

### Network wiring (TCP + TLS) — `overlays/network.yaml` · ⚠️ BETA

Wire prospero ↔ caliban over **TCP + TLS + bearer token** instead of the shared
Unix socket. caliband's network mode is newly landed and still hardening
(caliban [#319](https://github.com/caliban-ai/caliban/issues/319),
[#320](https://github.com/caliban-ai/caliban/issues/320)); prefer the base socket
wiring for production until those close.

```sh
./scripts/gen-certs.sh                         # CA + server cert (SAN=caliban) → ./certs
openssl rand -hex 32                            # → set CALIBAN_DAEMON_TOKEN in .env
docker compose -f compose.yaml -f overlays/network.yaml up -d
```

This overlay configures the caliban **server** side declaratively. prospero dials
caliband **per repo**, so you supply the endpoint when you register the repo
through prospero's API/dashboard: host `caliban:8443`, the bearer token
(`CALIBAN_DAEMON_TOKEN`), and the CA mounted at `/certs/ca.crt`. (This runtime
registration surface is evolving — see prospero
[#72](https://github.com/caliban-ai/prospero/issues/72).)

## Combining overlays

```sh
# Postgres + HTTPS edge
docker compose -f compose.yaml -f overlays/postgres.yaml -f overlays/proxy.yaml up -d

# Postgres + docker secrets
docker compose -f compose.yaml -f overlays/postgres.yaml -f overlays/secrets.yaml up -d
```

Later `-f` files override earlier ones.

## Operations

```sh
docker compose ps                 # status
docker compose logs -f prospero   # follow a service
docker compose pull               # fetch pinned image updates
docker compose down               # stop (volumes preserved)
docker compose down -v            # stop and delete volumes (destroys data)
```

## License

[AGPL-3.0-only](LICENSE), matching the rest of the caliban-ai suite.
