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

> ### Tested image cohort
>
> | Var | Pinned | Notes |
> |---|---|---|
> | `CALIBAN_VERSION` | `0.15.0` | |
> | `GONZALO_VERSION` | `0.7.0` | cannot read a `gonzalo-data` volume written by < 0.7 |
> | `PROSPERO_VERSION` | `0.8.1` | authenticates its API; see [API auth](#prospero-api-auth) |
>
> These three move as a **cohort**: prosperod and caliband share a control-plane
> wire contract (it moved into the `caliban-contract` crate in caliban 0.14.0),
> and gonzalo holds both their records. Bump all three together and re-run
> `./scripts/preflight.sh`, which flags a pin that is behind or was never
> published.

## Quick start

```sh
git clone https://github.com/caliban-ai/docker-compose
cd docker-compose

cp .env.example .env               # then edit: set ANTHROPIC_API_KEY
mkdir -p workspace                 # the repo/workspace caliban will supervise

./scripts/gen-prospero-auth.sh     # mint an API token — prints it once, copy it
./scripts/preflight.sh             # checks pins, auth material and volumes

docker compose up -d
open http://localhost:7878         # sign in with the token you just copied
```

Then register the workspace so prospero supervises it:

```sh
curl -X POST http://localhost:7878/api/workspaces \
  -H "Authorization: Bearer $PROSPERO_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"workspace","root":"/workspace"}'
```

The released `prospero` image contains only the `prosperod` daemon, not the
`prospero` CLI, so registration goes through the HTTP API (or the dashboard).
`GET /api/workspaces` should then report `"state": "healthy"`, which means
prospero reached caliband over the shared socket.

The base stack runs all three services with SQLite persistence and wires
prospero ↔ caliban over a shared Unix control socket — no TLS, no reverse proxy.

### Running as your own user

Every image runs as uid `10001`. If agents need to **write** to a bind-mounted
workspace (git worktrees, edits), run the services as the user that owns it:

```sh
printf 'CALIBAN_UID=%s\nCALIBAN_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
```

A one-shot `init` service chowns the named volumes to that uid before anything
starts, so the data volumes follow the same owner. Leave these unset to keep the
images' own uid, which is fine when nothing writes to the workspace from inside.

## prospero API auth

prosperod >= 0.8.0 authenticates every non-probe route, and refuses to bind a
non-loopback address with no tokens configured — this stack binds `0.0.0.0:7878`,
so the base `compose.yaml` passes `--api-tokens-file`.

```sh
./scripts/gen-prospero-auth.sh              # token `admin`, scope admin
./scripts/gen-prospero-auth.sh ci read      # a second, read-only token
```

The script appends a `<name> <scope> sha256:<hex>` line to
`secrets/prospero/tokens` and prints the token **once** — prosperod stores only
the hash, so a lost token cannot be recovered; mint another and delete the stale
line. It also writes `secrets/prospero/session.key`, the session-cookie key that
clustered prosperod (the Postgres overlay) requires. Both files are gitignored;
the directory is committed so Docker mounts it instead of creating it root-owned.

Scopes are `read`, `operate` (spawn/kill/input) and `admin` (workspaces, and
spawning unattended agents). Sign in to the dashboard with a token, or send
`Authorization: Bearer pspo_…`. Restart prospero after editing the file —
prosperod reads it only at startup.

To serve **unauthenticated** instead, stack `overlays/no-auth.yaml` last:

```sh
docker compose -f compose.yaml -f overlays/no-auth.yaml up -d
```

Anyone who can reach the published port then controls the fleet, so keep that
port private. prosperod logs the mode loudly on every start.

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
| `CALIBAN_VERSION` / `GONZALO_VERSION` / `PROSPERO_VERSION` | pinned image tags (move them as a cohort) | `0.15.0` / `0.7.0` / `0.8.1` |
| `ANTHROPIC_API_KEY` | caliban model credential (default provider) | — |
| `PROSPERO_HTTP_PORT` | host port for the dashboard | `7878` |
| `PROSPERO_HOST` | prosperod's fleet *identity* (not a backend selector) | `local` |
| `CALIBAN_WORKSPACE` | host dir caliban supervises | `./workspace` |
| `CALIBAN_UID` / `CALIBAN_GID` | run the services as this user (set to your own for a writable bind mount) | `10001` / `10001` |
| `RUST_LOG` | log verbosity | `info` |
| `POSTGRES_USER` / `_PASSWORD` / `_DB` | postgres overlay credentials | `prospero` / `change-me` / `prospero` |
| `PROSPERO_REPLICA_ID` | postgres overlay: clustered replica identity | `prospero-1` |
| `DOMAIN` | proxy overlay: hostname Caddy serves and gets certs for | `prospero.localhost` |
| `CALIBAN_DAEMON_TOKEN` / `_PORT` | network overlay: bearer token / TLS port | — / `8443` |

Pin images by digest (`0.7.0@sha256:…`) for fully reproducible deploys.

> **gonzalo volumes:** gonzalo >= 0.7.0 cannot read a `gonzalo-data` volume
> written by gonzalo < 0.7, and there is no in-place migration. If you somehow
> have one, remove it (`docker compose down && docker volume rm
> <project>_gonzalo-data`) and start fresh.

## Overlays (variants)

Stack overlay files with additional `-f` flags. Combine freely (except where noted).

### Postgres — `overlays/postgres.yaml`

Run prospero against Postgres instead of SQLite. Set `POSTGRES_*` in `.env`.

```sh
docker compose -f compose.yaml -f overlays/postgres.yaml up -d
```

Clustered prosperod with tokens also needs a session-cookie key so replicas sign
the same cookies; this overlay passes `--session-key-file`, and
`scripts/gen-prospero-auth.sh` writes the key alongside the tokens file.

### Unauthenticated API — `overlays/no-auth.yaml`

```sh
docker compose -f compose.yaml -f overlays/no-auth.yaml up -d
```

Replaces prospero's command to pass `--insecure-no-auth` instead of a tokens
file (prosperod refuses both together), so **stack it last**. See
[API auth](#prospero-api-auth) for what you are giving up.

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
