#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export TEST_DIAGNOSE="$tmp"
cat > "$tmp/bin/fly" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FLY_API_TOKEN" == 'FlyV1 test-token' ]]
printf '%s\n' "$*" >> "$TEST_DIAGNOSE/calls"
case "$1 $2" in
  'machine list') printf '[{"id":"abc1","state":"%s"}]\n' "${MOCK_STATE:-started}" ;;
  'logs --no-tail') echo 'Out of memory: Killed process (fixture)' ;;
  'ips list') echo 'Public IPs' ;;
  'machine exec')
    script=${4#*printf %s }
    printf '%s' "${script%% *}" | base64 -d > "$TEST_DIAGNOSE/streamed"
    echo '{"stdout":"PASS: remote checks\n"}' ;;
  *) echo "Unexpected mutation/command: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/hcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$HCLOUD_TOKEN" == test-token ]]
printf '%s\n' "$*" >> "$TEST_DIAGNOSE/calls"
case "$1 $2" in
  'server list') echo 'isabelle-byom' ;;
  'server describe')
    case "$*" in
      *Labels*) echo 'isabelle-byom' ;;
      *Status*) echo "${MOCK_STATE:-running}" ;;
      *PublicNet*) echo '203.0.113.10' ;;
      *) echo 'Server description' ;;
    esac ;;
  'server ssh')
    case "${!#}" in
      *'.env'*) echo 'BYOM_HOST=203.0.113.10.sslip.io' ;;
      *) cat > "$TEST_DIAGNOSE/streamed"; echo 'PASS: remote checks' ;;
    esac ;;
  *) echo "Unexpected mutation/command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
printf 'FlyV1 test-token\n' > "$tmp/fly.token"
printf 'test-token\n' > "$tmp/hetzner.token"
: > "$tmp/key"
FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly diagnose > "$tmp/result"
cmp "$root/server/diagnose.sh" "$tmp/streamed"
[[ $(cat "$tmp/result") == *'PASS: remote checks'* ]]
[[ $(cat "$tmp/result") == *'Fly logs record an out-of-memory termination'* ]]
HCLOUD_TOKEN=test-token "$root/byom" hetzner diagnose --ssh-key-file "$tmp/key" > "$tmp/result"
cmp "$root/server/diagnose.sh" "$tmp/streamed"
[[ $(cat "$tmp/calls") == *'docker compose exec -T isabelle bash -s -- wss://203.0.113.10.sslip.io/isabelle'* ]]
for provider in fly hetzner; do
  : > "$tmp/calls"
  if [[ "$provider" == fly ]]; then
    if MOCK_STATE=stopped "$root/byom" diagnose fly --token "$tmp/fly.token" > "$tmp/result" 2>&1; then exit 1; fi
  else
    if MOCK_STATE=off "$root/byom" diagnose hetzner --sslip --token "$tmp/hetzner.token" --ssh-key-file "$tmp/key" > "$tmp/result" 2>&1; then exit 1; fi
  fi
  [[ $(cat "$tmp/result") == *'FAIL:'* ]]
  [[ $(cat "$tmp/calls") != *'ssh '* && $(cat "$tmp/calls") != *'machine exec '* ]]
done
# Missing, incomplete and unreachable startup metadata must fail before credentials.
export BYOM_INFO="$tmp/missing"
if "$root/server/diagnose.sh" wss://example.org/isabelle > "$tmp/result" 2>&1; then exit 1; fi
[[ $(cat "$tmp/result") == *'startup metadata is missing'* ]]
printf 'starting\n' > "$BYOM_INFO"
if "$root/server/diagnose.sh" wss://example.org/isabelle > "$tmp/result" 2>&1; then exit 1; fi
[[ $(cat "$tmp/result") == *'has not reported a port/password'* ]]
printf 'server "byom" = 127.0.0.1:0 (password "test")\n' > "$BYOM_INFO"
if "$root/server/diagnose.sh" wss://example.org/isabelle > "$tmp/result" 2>&1; then exit 1; fi
[[ $(cat "$tmp/result") == *'Native TCP listener is unreachable'* ]]
[[ $(cat "$tmp/result") != *'PASSWORD='* ]]
echo 'Read-only diagnosis, token handoff, stopped-server and metadata failure checks passed.'
