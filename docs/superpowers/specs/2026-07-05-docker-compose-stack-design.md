# Design: `caliban-ai/docker-compose` — self-host stack for the caliban-ai suite

- **Date:** 2026-07-05
- **Status:** Approved (brainstorming) — ready for implementation planning
- **Repo:** `caliban-ai/docker-compose` (new)

## Purpose

Provide a Docker Compose stack that lets an operator self-host the caliban-ai
suite — **caliban** (agent supervisor), **gonzalo** (persistence / code-graph),
and **prospero** (fleet dashboard) — on a single host as a lightweight
alternative to the Kubernetes/helm path. It pulls pinned, published images from
GHCR, ships production-safe defaults, and persists state in named volumes.

Secondary goal: serve dev and demo audiences via composable overlay files rather
than separate copies of the stack.

## The three services (as-built)

| Service  | Binary      | Listens                                   | State           | Talks to                                  |
|----------|-------------|-------------------------------------------|-----------------|-------------------------------------------|
| gonzalo  | `gonzalod`  | HTTP `:8080`, gRPC `:50051`               | `/data` volume  | — (leaf persistence / code-graph MCP)     |
| caliban  | `caliband`  | Unix control socket in `$CALIBAN_DAEMON_RUNTIME_DIR`; TCP+TLS when `--listen`/`CALIBAN_DAEMON_LISTEN` set | XDG dirs under `/home/app` | gonzalo via MCP (`gonzalo:8080`) |
| prospero | `prosperod` | HTTP `:7878` (dashboard/SSE)              | `/data` volume  | caliban — Unix socket (default) or TCP+TLS+token (`connect_tcp`) |

Key facts that shaped the design:

- **prospero→caliban has two transports.** Default `LocalFleet` reaches caliband
  over a **Unix domain socket** at
  `${CALIBAN_DAEMON_RUNTIME_DIR:-$XDG_RUNTIME_DIR/caliban}/<hash16>.sock`.
  A **TCP + rustls TLS + bearer-token** transport also exists
  (`CalibandClient::connect_tcp`, prospero #71/#75; caliband `--listen` network
  mode, caliban #280 Task 7). The TCP path is **newly landed with open hardening
  tickets** (caliban #319, #320; gRPC migration #314) and prospero-side
  discovery work in flight (#72), so it is treated as **beta**.
- Both container images run as uid `10001` user `app`, so a shared named volume
  mounted at the runtime dir makes the Unix socket mutually accessible across the
  caliban and prospero containers on the same host.
- caliban needs `bubblewrap` + `git` (present in its image) and a **model
  provider credential** (Anthropic by default) to do useful work.
- prospero supports SQLite (default) or Postgres via `PROSPERO_DATABASE_URL`.
- The suite is licensed **AGPL-3.0-only** (prospero ADR 0009).

## Image availability (verified 2026-07-05)

| Service  | Latest release | GHCR container package        | Pullable tags              |
|----------|----------------|-------------------------------|----------------------------|
| gonzalo  | v0.1.0         | ✅ `ghcr.io/caliban-ai/gonzalo`  | `0.1.0`, `latest`, `sha-…` |
| prospero | v0.1.0         | ✅ `ghcr.io/caliban-ai/prospero` | `0.1.0`, `latest`, `sha-…` |
| caliban  | v0.4.0         | ❌ **not published** (org package 404) | none                 |

**Prerequisite (upstream, hard blocker):** `ghcr.io/caliban-ai/caliban` must be
published before the pull-based stack works end-to-end. Per decision, this is
treated purely as an upstream requirement — the compose repo does **not** ship a
build-from-source fallback. The README states the prerequisite explicitly and
pins `CALIBAN_VERSION` to the first published release.

## Approach

Chosen: **base compose file + composable overlay files** (`docker compose -f
compose.yaml -f overlays/<x>.yaml …`). The base runs the full suite with the
safest defaults; each overlay is a small, readable file toggling one axis.

Rejected alternatives: a single monolithic file toggled by env flags (hides
complexity in brittle interpolation); fully separate per-scenario files
(duplicates service definitions, drifts).

## Repository layout

```
docker-compose/
├─ compose.yaml               # BASE: full suite · socket wiring · sqlite · dashboard :7878
├─ .env.example               # pinned versions + config knobs (NO secrets); copy → .env
├─ .gitignore                 # .env, secrets/* (except .gitkeep/README), data/
├─ overlays/
│  ├─ network.yaml            # prospero↔caliban over TCP+TLS+token (BETA)
│  ├─ postgres.yaml           # prospero on a Postgres service
│  ├─ proxy.yaml              # Caddy HTTPS edge in front of prospero (+ gonzalo)
│  └─ secrets.yaml            # docker `secrets:` for API key + daemon token
├─ config/
│  └─ Caddyfile               # for the proxy overlay
├─ secrets/
│  ├─ .gitkeep
│  └─ README.md               # what files go here; contents gitignored
├─ scripts/
│  ├─ gen-certs.sh            # self-signed CA + caliband server cert (network overlay)
│  └─ preflight.sh            # checks docker/compose version, .env presence, required keys
├─ .github/
│  └─ workflows/ci.yml        # `docker compose config -q` lint across base + overlay combos
├─ README.md
└─ LICENSE                    # AGPL-3.0-only (matches suite / prospero ADR 0009)
```

## Base stack (`compose.yaml`) — zero-config default

`docker compose up` brings up all three services: dashboard at
`http://localhost:${PROSPERO_HTTP_PORT:-7878}`, SQLite persistence, Unix-socket
wiring, no TLS.

### Services

- **gonzalo**
  - `image: ghcr.io/caliban-ai/gonzalo:${GONZALO_VERSION}`
  - `volumes: [gonzalo-data:/data]`
  - `healthcheck`: HTTP GET `/health` on `:8080` (gonzalo #63 readiness endpoint)
  - No host port published by default (internal-only; reachable by caliban on the
    compose network as `gonzalo:8080` / `gonzalo:50051`).

- **caliban**
  - `image: ghcr.io/caliban-ai/caliban:${CALIBAN_VERSION}`
  - Runs `caliband` as a foreground daemon (exact run subcommand/args to be
    confirmed during implementation — base image `CMD` is `--help`).
  - `environment`: `ANTHROPIC_API_KEY` (from `.env`); MCP configured to reach
    gonzalo at `gonzalo:8080`; `CALIBAN_DAEMON_RUNTIME_DIR=/run/caliban`.
  - `volumes: [caliban-runtime:/run/caliban]` — the shared runtime dir.
  - `depends_on: [gonzalo]`.

- **prospero**
  - `image: ghcr.io/caliban-ai/prospero:${PROSPERO_VERSION}`
  - `ports: ["${PROSPERO_HTTP_PORT:-7878}:7878"]`
  - `volumes: [prospero-data:/data, caliban-runtime:/run/caliban]`
  - `environment`: `PROSPERO_ADDR=0.0.0.0:7878`,
    `PROSPERO_DATABASE_URL=sqlite:///data/prospero.db`, `PROSPERO_FLEET=local`,
    `CALIBAN_DAEMON_RUNTIME_DIR=/run/caliban`.
  - `depends_on: [caliban]`.

### Named volumes
`gonzalo-data`, `prospero-data`, `caliban-runtime` (the last shared between
caliban and prospero for the control socket).

### Subsets
Run a subset by naming services: `docker compose up gonzalo caliban`. Optional
add-on services (postgres, caddy) live behind compose `profiles:` so they never
start unless their overlay + profile is selected. No dedicated "scope" overlay
files are needed.

## Overlays

Each overlay is applied with additional `-f` flags and only overrides/extends the
base.

### `overlays/network.yaml` — TCP+TLS+token wiring (BETA)
- **caliban:** `CALIBAN_DAEMON_LISTEN=0.0.0.0:8443`, mount TLS cert/key
  (`CALIBAN_DAEMON_TLS_CERT`, `CALIBAN_DAEMON_TLS_KEY`), `CALIBAN_DAEMON_TOKEN`,
  `CALIBAN_DAEMON_ADVERTISE_HOST=caliban`. Expose `8443` on the compose network.
- **prospero:** point `LocalFleet` at the caliban TCP endpoint with the CA +
  bearer token. **The exact prospero-side dial configuration
  (env/registry/discovery surface) must be confirmed against `prospero`'s
  `crates/core/src/fleet.rs` + `caliband/client.rs` during implementation**; it
  ties to prospero #72 (workspace-scoped discovery).
- Drops the shared `caliban-runtime` socket volume from both services.
- Certs generated by `scripts/gen-certs.sh` (self-signed CA + server cert with
  SAN `caliban`).
- README marks this overlay **beta**, referencing caliban #319/#320.

### `overlays/postgres.yaml` — Postgres backend for prospero
- Adds `postgres` service (`image: postgres:16`, profile `postgres`,
  `postgres-data:/var/lib/postgresql/data`, `POSTGRES_*` from `.env`, healthcheck
  via `pg_isready`).
- Overrides prospero `PROSPERO_DATABASE_URL=postgres://…@postgres:5432/prospero`
  and adds `depends_on: {postgres: {condition: service_healthy}}`.

### `overlays/proxy.yaml` — Caddy HTTPS edge
- Adds `caddy` service (profile `proxy`, `config/Caddyfile`, ports `80`/`443`,
  `caddy-data`/`caddy-config` volumes). `${DOMAIN}` → `reverse_proxy
  prospero:7878` (optionally also gonzalo).
- Removes prospero's direct host port publish so the dashboard is reached only
  through the proxy.

### `overlays/secrets.yaml` — docker secrets for credentials
- Declares top-level `secrets:` (`anthropic_api_key`, `caliban_daemon_token`)
  sourced from `./secrets/*` files.
- Mounts them at `/run/secrets/*` and wires them via caliban's file/helper key
  mechanism instead of plain env (exact mechanism — `*_FILE` convention vs
  `CALIBAN_API_KEY_HELPER` — confirmed during implementation).
- This is the hardened counterpart to the `.env` default; the two are mutually
  exclusive for a given credential.

## Configuration & credentials

- **`.env.example`** (copied to `.env`, gitignored) pins image versions and
  exposes knobs:
  - `CALIBAN_VERSION` (pinned to first published caliban release),
    `GONZALO_VERSION=0.1.0`, `PROSPERO_VERSION=0.1.0`.
  - `ANTHROPIC_API_KEY=` (documented default provider; Bedrock `AWS_*` / Vertex
    GCP creds mentioned as user-supplied passthrough).
  - `PROSPERO_HTTP_PORT=7878`, `DOMAIN=` (proxy), `POSTGRES_*` (postgres overlay).
  - Digest pinning (`…@sha256:…`) documented as the hardened alternative to
    semver tags.
- **Credentials:** `.env` is the easy default path; `overlays/secrets.yaml`
  provides docker-secrets for hardened deployments. Both are documented.

## CI / testing

- `.github/workflows/ci.yml` runs `docker compose config -q` (or `--quiet`) over
  the base file and every valid base+overlay combination on PRs, catching YAML
  and interpolation errors without needing images or credentials.
- `scripts/preflight.sh` performs local sanity checks (docker/compose version,
  `.env` present, required keys set) before `up`.
- No live end-to-end smoke test in CI initially — it would require the published
  caliban image and a real API key. Deferred to a follow-up once the caliban
  image is published.

## Risks & open items (resolved during implementation planning)

1. **caliban image not published** — upstream hard prerequisite; no build
   fallback in this repo (by decision). README states it plainly.
2. **caliband daemon run command** — base image `CMD` is `--help`; the actual
   foreground-daemon invocation must be confirmed from
   `caliban/crates/caliban-supervisor/src/bin/caliband.rs`.
3. **prospero TCP dial config** — the precise env/discovery surface for the
   network overlay must be confirmed from prospero `fleet.rs`/`client.rs`; ties
   to #72. Overlay ships marked beta.
4. **caliban secrets mechanism** — confirm `*_FILE` vs API-key-helper before
   finalizing `secrets.yaml`.

## Out of scope (v1)

- Live end-to-end CI smoke test.
- Build-from-source path for any service.
- Kubernetes/helm concerns (covered by `caliban-ai/helm-charts`).
- Multi-host / clustered prospero HA (compose is single-host by nature).
