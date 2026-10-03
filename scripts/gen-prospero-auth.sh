#!/usr/bin/env bash
# Mint prospero API credentials for this stack.
#
#   scripts/gen-prospero-auth.sh                 # token `admin`, scope admin
#   scripts/gen-prospero-auth.sh ci read         # token `ci`, scope read
#
# Appends one line to secrets/prospero/tokens and prints the token ONCE.
# prosperod stores only the SHA-256 hash, so a lost token cannot be recovered —
# mint another and delete the stale line.
#
# Also creates secrets/prospero/session.key, the session-cookie HMAC key that
# clustered prosperod (the postgres overlay) requires alongside tokens.
#
# The released prospero image ships only `prosperod`, not the `prospero` CLI, so
# the token is generated here in the exact format prosperod parses:
#   <name> <scope> sha256:<hex>     hash = SHA-256 over the full token string
#   token = "pspo_" + base64url(32 random bytes), unpadded
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:-admin}"
scope="${2:-admin}"
dir=secrets/prospero
tokens="$dir/tokens"
session_key="$dir/session.key"

case "$scope" in
  read|operate|admin) ;;
  *) echo "error: scope must be read, operate or admin (got '$scope')" >&2; exit 1 ;;
esac

# prosperod's own rule: [a-z0-9][a-z0-9_-]{0,62}
if ! printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,62}$'; then
  echo "error: invalid token name '$name' (expected [a-z0-9][a-z0-9_-]{0,62})" >&2
  exit 1
fi

mkdir -p "$dir"

if [ -f "$tokens" ] && grep -Eq "^${name}[[:space:]]" "$tokens"; then
  echo "error: a token named '$name' already exists in $tokens" >&2
  echo "       delete that line first, or choose another name" >&2
  exit 1
fi

# 32 random bytes, base64url, unpadded.
token="pspo_$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
hash="$(printf '%s' "$token" | openssl dgst -sha256 -hex | awk '{print $NF}')"

umask 077
printf '%s %s sha256:%s\n' "$name" "$scope" "$hash" >> "$tokens"
chmod 600 "$tokens"

if [ -f "$session_key" ]; then
  echo "session key: $session_key (kept)"
else
  openssl rand -base64 48 > "$session_key"
  chmod 600 "$session_key"
  echo "session key: $session_key (created)"
fi

cat <<MSG

token '$name' (scope $scope) added to $tokens

  $token

Copy it now — it is not stored and cannot be shown again.
Sign in to the dashboard with it, or send it as:  Authorization: Bearer $token
MSG
