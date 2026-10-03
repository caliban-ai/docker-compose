# caliban-ai/docker-compose

Docker Compose stack for self-hosting the **caliban-ai** suite on a single host:

| Service | Role | Image | Docs |
|---|---|---|---|
| [**caliban**](https://github.com/caliban-ai/caliban) | per-workspace agent supervisor (`caliband`) | `ghcr.io/caliban-ai/caliban` | [site](https://caliban-ai.github.io/caliban/) |
| [**gonzalo**](https://github.com/caliban-ai/gonzalo) | persistence / code-graph MCP server | `ghcr.io/caliban-ai/gonzalo` | [site](https://caliban-ai.github.io/gonzalo/) |
| [**prospero**](https://github.com/caliban-ai/prospero) | fleet dashboard / control plane | `ghcr.io/caliban-ai/prospero` | [site](https://caliban-ai.github.io/prospero/) |

It pulls pinned, published images from GHCR, ships production-safe defaults, and
persists state in named volumes. For Kubernetes, use
[`caliban-ai/helm-charts`](https://github.com/caliban-ai/helm-charts) instead.

[**ariel**](https://caliban-ai.github.io/ariel/), the suite's Discord chat
bridge, is **not** part of this stack — it is only packaged as a Helm chart today.

> ### ⚠️ This stack's image pins are stale and it will not start as shipped
>
> All three images are published on GHCR, but the versions pinned in
> `.env.example` are from July 2026 — and **`CALIBAN_VERSION=0.4.0` was never
> published at all** (the oldest `ghcr.io/caliban-ai/caliban` tag is `0.5.0`), so
> `docker compose up` fails to pull.
>
> | Var | Pinned | Published latest |
> |---|---|---|
> | `CALIBAN_VERSION` | `0.4.0` ✗ not a real tag | `0.15.0` |
> | `GONZALO_VERSION` | `0.2.0` | `0.7.0` |
> | `PROSPERO_VERSION` | `0.1.0` | `0.8.1` |
>
> The pins move as a **cohort** — prosperod and caliband share a control-plane
> wire contract, and gonzalo holds both their records — so revising them is one
> tested change, not three tag bumps. The blockers are listed in `.env.example`
> next to the pins: prospero >= 0.8.0 is breaking for deployments (it refuses a
> non-loopback `--addr` without API tokens, and `compose.yaml` binds
> `0.0.0.0:7878`), and gonzalo 0.7.0 changes how deletion replicates and adds
> record kinds a 0.2 binary cannot decode.
>
> Until that lands, use the [Helm charts](https://github.com/caliban-ai/helm-charts),
> whose CI proves the current cohort comes up and reconciles a task.

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

(Read the version warning above first: as pinned, the `caliban` image tag does
not exist, so this will fail at the pull.)

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
| `CALIBAN_VERSION` / `GONZALO_VERSION` / `PROSPERO_VERSION` | pinned image tags (**stale — see the warning above**) | see `.env.example` |
| `ANTHROPIC_API_KEY` | caliban model credential (default provider) | — |
| `PROSPERO_HTTP_PORT` | host port for the dashboard | `7878` |
| `PROSPERO_HOST` | prosperod's fleet *identity* (not a backend selector) | `local` |
| `CALIBAN_WORKSPACE` | host dir caliban supervises | `./workspace` |
| `RUST_LOG` | log verbosity | `info` |
| `POSTGRES_USER` / `_PASSWORD` / `_DB` | postgres overlay credentials | `prospero` / `change-me` / `prospero` |
| `PROSPERO_REPLICA_ID` | postgres overlay: clustered replica identity | `prospero-1` |
| `DOMAIN` | proxy overlay: hostname Caddy serves and gets certs for | `prospero.localhost` |
| `CALIBAN_DAEMON_TOKEN` / `_PORT` | network overlay: bearer token / TLS port | — / `8443` |

Pin images by digest (`0.7.0@sha256:…`) for fully reproducible deploys.

> **Not configured here:** prospero >= 0.8.0 needs an API-auth decision
> (`PROSPERO_API_TOKENS_FILE`, or `PROSPERO_INSECURE_NO_AUTH=1` to opt out) before
> it will bind `0.0.0.0`. The pinned `PROSPERO_VERSION=0.1.0` predates that, which
> is why `compose.yaml` sets neither — any bump has to add one.

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

### Network wiring (TCP + TLS) — `overlays/network.yaml`

Wire prospero ↔ caliban over **TCP + TLS + bearer token** instead of the shared
Unix socket.

caliband's network mode has since been hardened — the issues this overlay used to
warn about (caliban [#319](https://github.com/caliban-ai/caliban/issues/319)
accept timeout / worker status under TLS / advertise-host,
[#320](https://github.com/caliban-ai/caliban/issues/320) pinned crypto provider +
negative-path TLS tests) are **closed**, as is the discovery rework
(prospero [#72](https://github.com/caliban-ai/prospero/issues/72), which made
discovery workspace-scoped rather than per-repo). The base Unix-socket wiring is
still the simpler default; the one thing to know before building on this overlay
is that caliban
[#314](https://github.com/caliban-ai/caliban/issues/314) will migrate the
transport from NDJSON over TCP+TLS to native gRPC, which changes the wire.

```sh
./scripts/gen-certs.sh                         # CA + server cert (SAN=caliban) → ./certs
openssl rand -hex 32                            # → set CALIBAN_DAEMON_TOKEN in .env
docker compose -f compose.yaml -f overlays/network.yaml up -d
```

This overlay configures the caliban **server** side declaratively. prospero dials
caliband per **workspace**, so you supply the endpoint when you register it
through prospero's API/dashboard: host `caliban:8443`, the bearer token
(`CALIBAN_DAEMON_TOKEN`), and the CA mounted at `/certs/ca.crt`.

## Combining overlays

```sh
# Postgres + HTTPS edge
docker compose -f compose.yaml -f overlays/postgres.yaml -f overlays/proxy.yaml up -d

# Postgres + docker secrets
docker compose -f compose.yaml -f overlays/postgres.yaml -f overlays/secrets.yaml up -d

# TCP+TLS wiring + docker secrets (the secrets entrypoint keeps caliban's
# command args, so it composes with network.yaml)
docker compose -f compose.yaml -f overlays/network.yaml -f overlays/secrets.yaml up -d
```

Later `-f` files override earlier ones. All four overlays compose with each
other; CI validates the base plus every overlay alone and the two Postgres pairs
above (`.github/workflows/ci.yml`).

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
