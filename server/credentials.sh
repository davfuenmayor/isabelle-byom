#!/usr/bin/env bash
# Runs inside the Machine. Authenticate through its public TLS endpoint first.
set -euo pipefail
url=${1:?Usage: credentials.sh WSS_URL}
info=${BYOM_INFO:-/tmp/byom-server.info}
password=''
for ((attempt=0; attempt<120; attempt++)); do
  password=$(sed -n 's/.*(password "\([^"]*\)").*/\1/p' "$info" 2>/dev/null | head -n1) || true
  [[ -n "$password" ]] && break
  sleep 1
done
[[ -n "$password" ]] || { echo 'Server password startup timed out' >&2; exit 1; }
result=$(mktemp)
trap 'rm -f "$result"' EXIT
# -n keeps the read direction open after stdin EOF. timeout bounds that wait.
printf '%s\necho "byom-ready"\n' "$password" |
  timeout 10 websocat -b -n "$url" > "$result" 2>/dev/null || true
if ! grep -Fxq 'OK "byom-ready"' "$result"; then
  echo 'Public WSS authentication/echo failed' >&2
  exit 1
fi
printf 'URL=%s\nPASSWORD=%s\n' "$url" "$password"
