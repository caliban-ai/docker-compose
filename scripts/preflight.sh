#!/usr/bin/env bash
# Sanity-check the host before `docker compose up`. Non-fatal warnings for the
# things that most often trip up a first run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
err()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }

echo "==> docker"
if command -v docker >/dev/null 2>&1; then
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '(daemon not reachable)')"
  if docker compose version >/dev/null 2>&1; then ok "compose plugin present"; else err "docker compose plugin missing"; fi
else
  err "docker not found on PATH"
fi

echo "==> .env"
if [ -f .env ]; then
  ok ".env present"
  set -a
  # shellcheck disable=SC1091
  . ./.env 2>/dev/null || true
  set +a
  for v in CALIBAN_VERSION GONZALO_VERSION PROSPERO_VERSION; do
    if [ -n "${!v:-}" ]; then ok "$v=${!v}"; else err "$v unset"; fi
  done
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "ANTHROPIC_API_KEY set"
  else
    warn "ANTHROPIC_API_KEY empty — set it, or use the secrets overlay"
  fi
else
  err ".env missing — run: cp .env.example .env"
fi

echo "==> workspace"
WS="${CALIBAN_WORKSPACE:-./workspace}"
if [ -d "$WS" ]; then ok "workspace dir $WS exists"; else warn "workspace dir $WS missing — run: mkdir -p ${WS#./}"; fi

echo "==> image pins"
# The three images move as a cohort (prosperod and caliband share a wire
# contract). Current published cohort: caliban 0.15.0, gonzalo 0.7.0,
# prospero 0.8.1.
case "${CALIBAN_VERSION:-}" in
  0.4.0|0.4.0@*)
    err "CALIBAN_VERSION=$CALIBAN_VERSION was never published (oldest 0.5.0, latest 0.15.0) — the pull will fail"
    ;;
  0.1[5-9].*|0.[2-9][0-9].*) ok "CALIBAN_VERSION=$CALIBAN_VERSION" ;;
  "") ;;
  *) warn "CALIBAN_VERSION=$CALIBAN_VERSION is behind the tested cohort (caliban 0.15.0)" ;;
esac
case "${GONZALO_VERSION:-}" in
  0.[7-9].*|0.[1-9][0-9].*) ok "GONZALO_VERSION=$GONZALO_VERSION" ;;
  "") ;;
  *) warn "GONZALO_VERSION=$GONZALO_VERSION predates 0.7.0; its gonzalo-data volume format is not supported by the cohort" ;;
esac
case "${PROSPERO_VERSION:-}" in
  0.[8-9].*|0.[1-9][0-9].*) ok "PROSPERO_VERSION=$PROSPERO_VERSION" ;;
  "") ;;
  *) warn "PROSPERO_VERSION=$PROSPERO_VERSION is behind the tested cohort (prospero 0.8.1)" ;;
esac

echo "==> prospero API auth"
# prosperod >= 0.8.0 refuses a non-loopback --addr with no tokens, and this
# stack binds 0.0.0.0. The base compose passes --api-tokens-file, so the file
# must exist before `up`.
if [ -f secrets/prospero/tokens ]; then
  if [ -s secrets/prospero/tokens ]; then
    ok "secrets/prospero/tokens present ($(grep -cvE '^[[:space:]]*(#|$)' secrets/prospero/tokens) token(s))"
  else
    err "secrets/prospero/tokens is empty — prosperod rejects a tokens file with no tokens"
  fi
  if [ -f secrets/prospero/session.key ]; then
    ok "secrets/prospero/session.key present (needed when clustered)"
  else
    warn "secrets/prospero/session.key missing — required with the postgres overlay (clustered + tokens)"
  fi
else
  err "secrets/prospero/tokens missing — run: scripts/gen-prospero-auth.sh"
  warn "  (or serve unauthenticated by stacking overlays/no-auth.yaml last)"
fi

echo "==> existing volumes"
# gonzalo >= 0.7 cannot read a volume written by gonzalo < 0.7, and there is no
# in-place migration.
if command -v docker >/dev/null 2>&1; then
  vols="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_gonzalo-data$' || true)"
  if [ -n "$vols" ]; then
    warn "existing gonzalo volume(s): $(echo "$vols" | tr '\n' ' ')"
    warn "  if written by gonzalo < 0.7, remove it — the cohort cannot read that format"
  else
    ok "no pre-existing gonzalo-data volume"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "preflight: no blocking issues"; else echo "preflight: blocking issues above"; fi
exit "$fail"
