#!/usr/bin/env bash
# Read-only checks, streamed by the provider CLI into an existing instance.
set -euo pipefail
url=${1:?Usage: diagnose.sh PUBLIC_WSS_URL}
info=${BYOM_INFO:-/tmp/byom-server.info}
[[ -r "$info" ]] || { echo 'FAIL: Isabelle startup metadata is missing; inspect server startup logs.' >&2; exit 1; }
port=$(sed -n 's/^server "[^"]*" = 127\.0\.0\.1:\([0-9]*\) (password "[^"]*").*/\1/p' "$info" | head -n1)
password=$(sed -n 's/.*(password "\([^"]*\)").*/\1/p' "$info" | head -n1)
[[ -n "$port" && -n "$password" ]] || { echo 'FAIL: Isabelle has not reported a port/password; inspect startup logs.' >&2; exit 1; }
printf 'Runtime JVM options: %s\n' "${BYOM_JAVA_OPTIONS:-Isabelle default}"
echo "Checking native Isabelle on loopback port $port..."
exec 3<> "/dev/tcp/127.0.0.1/$port" || { echo 'FAIL: Native TCP listener is unreachable.' >&2; exit 1; }
printf '%s\necho "byom-diagnose"\nhelp\n' "$password" >&3
native_ok=false
commands_ok=false
while IFS= read -r -t 5 line <&3; do
  if [[ "$line" == 'OK "byom-diagnose"' ]]; then native_ok=true; fi
  if [[ "$line" == 'OK ['* ]]; then
    if [[ "$line" == *'"byom_write_file"'* && "$line" == *'"byom_create_project"'* ]]; then commands_ok=true; fi
    break
  fi
done
exec 3>&- 3<&-
$native_ok || { echo 'FAIL: Native authentication/echo failed.' >&2; exit 1; }
$commands_ok || { echo 'FAIL: BYOM file commands are missing; check component registration.' >&2; exit 1; }
echo 'PASS: Native authentication, echo and file-command registration.'
echo "Checking public TLS/WebSocket tunnel: $url"
# Reuse verification from the deployed image; keep its credentials until success.
credentials=$("${BYOM_CREDENTIALS_TOOL:-/opt/byom/credentials.sh}" "$url")
echo 'PASS: Public WSS authentication and echo.'
echo 'Use the current PASSWORD below in Livebook. A stale password can cause a connection close after about five seconds.'
printf '\n=== Isabelle server credentials ===\n%s\n===================================\n' "$credentials"
