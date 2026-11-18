#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/hcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$HCLOUD_TOKEN" == test-token ]]
printf '%s\n' "$*" >> "$MOCK_STATE/calls"
case "$1 $2" in
  'server list') [[ ! -f "$MOCK_STATE/server" ]] || echo isabelle-byom ;;
  'server-type describe') echo "${MOCK_ARCH:-x86}" ;;
  'ssh-key list'|'firewall list') : ;;
  'ssh-key create'|'firewall create') : ;;
  'server create') touch "$MOCK_STATE/server" ;;
  'firewall apply-to-resource') echo firewall_already_applied >&2; exit 1 ;;
  'server describe')
    case "$*" in
      *Labels*) echo "${MOCK_OWNER:-isabelle-byom}" ;;
      *PublicNet*) echo 203.0.113.10 ;;
    esac ;;
  'server ssh')
    # hcloud preserves everything following the server name; do not pass --.
    [[ "$4" == -i ]]
    echo 'SSH connected' >&2
    command=${!#}
    case "$command" in
      'tar -xf '*) tar -tf - > "$MOCK_STATE/archive" ;;
      *credentials.sh*)
        printf 'URL=wss://203.0.113.10.sslip.io/isabelle\nPASSWORD=test-password\n'
        [[ ${MOCK_VERIFY_FAIL:-0} == 0 ]] || exit 1
        ;;
      *'docker compose up'*) echo 'Building image'; echo 'Starting containers' >&2 ;;
    esac ;;
  *) echo "Unexpected command: $*" >&2; exit 1 ;;
esac
exit 0
MOCK
chmod +x "$tmp/bin/hcloud"
export PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp"
printf 'test-token\n' > "$tmp/token with spaces"
run() { "$root/byom" hetzner --sslip --token "$tmp/token with spaces" --ssh-key-file "$tmp/key"; }
# A file takes precedence over the environment.
HCLOUD_TOKEN=invalid run > "$tmp/result" 2> "$tmp/errors"
run > "$tmp/result" 2> "$tmp/errors"
expected=$'=== Isabelle server credentials ===\nURL=wss://203.0.113.10.sslip.io/isabelle\nPASSWORD=test-password\n==================================='
[[ $(cat "$tmp/result") == *"$expected" ]]
[[ $(grep -c '^PASSWORD=' "$tmp/result") == 1 ]]
[[ $(cat "$tmp/result") == *$'Building image\nStarting containers'* ]]
[[ $(cat "$tmp/result") == *$'SSH connected\n\n=== Isabelle server credentials ==='* ]]
[[ ! -s "$tmp/errors" ]]
[[ $(awk '/^server create / {n++} END {print n}' "$tmp/calls") == 1 ]]
archive=$(cat "$tmp/archive")
[[ "$archive" == *server/component/src/byom.scala* && "$archive" != *token* && "$archive" != *byom.jar* ]]
if MOCK_OWNER=someone-else "$root/byom" hetzner --sslip --token "$tmp/token with spaces" --ssh-key-file "$tmp/unused-key" > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -e "$tmp/unused-key" ]]
[[ ! -s "$tmp/result" ]]
if MOCK_ARCH=arm run > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" ]]
# A separate runner can authenticate with only the supplied environment token.
HCLOUD_TOKEN=test-token "$root/byom" hetzner --sslip --ssh-key-file "$tmp/key" < /dev/null > "$tmp/result" 2> "$tmp/errors"
[[ $(cat "$tmp/result") == *"$expected" ]]
# An unset or empty environment falls back to the prompt.
printf 'test-token\n' | (unset HCLOUD_TOKEN; exec "$root/byom" hetzner --sslip --ssh-key-file "$tmp/key") > "$tmp/result" 2> "$tmp/errors"
[[ $(cat "$tmp/result") == *"$expected" ]]
printf 'test-token\n' | HCLOUD_TOKEN='' "$root/byom" hetzner --sslip --ssh-key-file "$tmp/key" > "$tmp/result" 2> "$tmp/errors"
[[ $(cat "$tmp/result") == *"$expected" ]]
# An explicitly empty file must fail even if an environment token is available.
: > "$tmp/empty-token"
if HCLOUD_TOKEN=test-token "$root/byom" hetzner --sslip --token "$tmp/empty-token" --ssh-key-file "$tmp/key" > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" ]]
# Verification may produce partial output and fail; never display those credentials.
cat > "$tmp/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$tmp/bin/sleep"
if MOCK_VERIFY_FAIL=1 run > "$tmp/result" 2> "$tmp/errors"; then
  echo 'Failed verification was ignored' >&2; exit 1
fi
[[ $(cat "$tmp/result") == *'Building image'* ]]
[[ $(cat "$tmp/result") != *'PASSWORD='* && $(cat "$tmp/result") != *'=== Isabelle server credentials ==='* ]]
echo 'Hetzner token precedence, provisioning, reuse, archive and credentials checks passed.'
