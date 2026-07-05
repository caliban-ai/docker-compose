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

echo "==> caliban image"
warn "ghcr.io/caliban-ai/caliban must be published before the caliban service can pull (upstream prerequisite)"

echo
if [ "$fail" -eq 0 ]; then echo "preflight: no blocking issues"; else echo "preflight: blocking issues above"; fi
exit "$fail"
