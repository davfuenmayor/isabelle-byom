#!/usr/bin/env bash
# Read server metadata and authenticate through the client endpoint.
set -euo pipefail
url=${1:?Usage: credentials.sh WEBSOCKET_URL}
info=${BYOM_INFO:-/tmp/byom-server.info}
password=''
for ((attempt=0; attempt<120; attempt++)); do
  password=$(sed -n 's/.*(password "\([^"]*\)").*/\1/p' "$info" 2>/dev/null | head -n1) || true
  [[ -n "$password" ]] && break
  sleep 1
done
[[ -n "$password" ]] || { echo 'Server password startup timed out' >&2; exit 1; }
# -n keeps the read direction open after the two request lines.
exec 3< <(exec websocat -b -n "$url" <<< "$password"$'\necho "byom-ready"' 2>/dev/null)
probe=$!
trap 'kill "$probe" 2>/dev/null || true; wait "$probe" 2>/dev/null || true' EXIT
deadline=$((SECONDS + 5))
while ((SECONDS < deadline)) && IFS= read -r -t "$((deadline - SECONDS))" reply <&3; do
  if [[ "$reply" == 'OK "byom-ready"' ]]; then
    printf 'URL=%s\nPASSWORD=%s\n' "$url" "$password"
    exit 0
  fi
done
echo 'WebSocket authentication/echo failed' >&2
exit 1
