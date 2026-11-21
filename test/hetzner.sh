#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/provider"
cat > "$tmp/bin/hcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$HCLOUD_TOKEN" == test-token ]]
printf '%s\n' "$*" >> "$MOCK_STATE/calls"
p="$MOCK_STATE/provider"
case "$1 $2" in
  'server list') [[ ! -f "$p/power" ]] || echo isabelle-byom ;;
  'server-type describe') echo "${MOCK_ARCH:-x86}" ;;
  'ssh-key list'|'firewall list')
    if [[ -e "$p/$1" ]]; then echo byom-isabelle-byom; fi ;;
  'ssh-key create'|'firewall create')
    [[ "$*" == *'--label isabelle-byom=isabelle-byom'* ]]
    touch "$p/$1" ;;
  'ssh-key describe') ssh-keygen -y -f "$MOCK_STATE/key" ;;
  'ssh-key delete'|'firewall delete') rm "$p/$1" ;;
  'server create')
    [[ "$*" == *'--start-after-create=false'* && "$*" == *'--firewall byom-isabelle-byom'* ]]
    echo off > "$p/power" ;;
  'server delete')
    [[ $(cat "$p/power") == off ]]
    rm "$p/power" "$p/env" ;;
  'server shutdown')
    echo off > "$p/power"
    if [[ -f "$p/serving" ]]; then rm "$p/serving"; fi ;;
  'server poweron') echo running > "$p/power" ;;
  'server describe')
    case "$*" in
      *Labels*) echo "${MOCK_OWNER:-isabelle-byom}" ;;
      *PublicNet*) echo 203.0.113.10 ;;
      *Status*) cat "$p/power" ;;
    esac ;;
  'server ssh')
    [[ "$4" == -i && $(cat "$p/power") == running ]]
    echo 'SSH connected' >&2
    command=${!#}
    case "$command" in
      'tar -xf '*) tar -tf - > "$MOCK_STATE/archive" ;;
      *credentials.sh*)
        [[ -f "$p/serving" ]]
        printf 'URL=wss://203.0.113.10.sslip.io/isabelle\nPASSWORD=test-password\n'
        [[ ${MOCK_VERIFY_FAIL:-0} == 0 ]] || exit 1 ;;
      *'docker compose pull'*)
        [[ ${MOCK_PULL_FAIL:-0} == 0 ]] || exit 1
        [[ "$command" == *'docker compose create'* ]]
        image=$(sed -E "s/.*BYOM_IMAGE='([^']+)'.*/\1/" <<< "$command")
        printf 'BYOM_HOST=203.0.113.10.sslip.io\nBYOM_IMAGE=%s\n' "$image" > "$p/env" ;;
      *'.env'*) if [[ -f "$p/env" ]]; then cat "$p/env"; fi ;;
      *'ps --status running'*) if [[ -f "$p/serving" ]]; then echo isabelle; fi ;;
      *'docker compose start'*) touch "$p/serving" ;;
      'true'|'mkdir -p /opt/isabelle-byom'|'bash /opt/isabelle-byom/providers/hetzner/bootstrap.sh') : ;;
      *) echo "Unexpected SSH command: $command" >&2; exit 1 ;;
    esac ;;
  *) echo "Unexpected command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/hcloud"
export PATH="$tmp/bin:$PATH" HCLOUD_TOKEN=test-token MOCK_STATE="$tmp"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
printf 'test-token\n' > "$tmp/token with spaces"
printf -v digest '%064d' 1
image="registry.example.org/isabelle-byom@sha256:$digest"
expected=$'=== Isabelle server credentials ===\nURL=wss://203.0.113.10.sslip.io/isabelle\nPASSWORD=test-password\n==================================='
run() { "$root/byom" hetzner "$@" --ssh-key-file "$tmp/key"; }

if run start > "$tmp/result" 2>&1; then exit 1; fi
if MOCK_ARCH=arm run deploy "$image" --sslip > "$tmp/result" 2>&1; then exit 1; fi
[[ -z $(ls -A "$tmp/provider") ]]
# Deliver the same deployment twice, then remove exactly the provider resources it created.
HCLOUD_TOKEN=invalid run deploy "$image" --sslip --token "$tmp/token with spaces" > "$tmp/result"
[[ $(cat "$tmp/provider/power") == off && ! -f "$tmp/provider/serving" ]]
grep -Fq "BYOM_IMAGE=$image" "$tmp/provider/env"
grep -Fxq providers/hetzner/compose.yaml "$tmp/archive"
if grep -q '^PASSWORD=' "$tmp/result"; then exit 1; fi
run deploy "$image" > "$tmp/result"
[[ $(grep -Fc 'docker compose pull' "$tmp/calls") == 1 ]]
run destroy
run destroy
[[ -z $(ls -A "$tmp/provider") && -s "$tmp/key" ]]

run deploy "$image" --sslip > "$tmp/result"
cp -R "$tmp/provider" "$tmp/staged"
run start > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
if run destroy > "$tmp/result" 2>&1; then exit 1; fi
printf -v other '%064d' 2
other="registry.example.org/isabelle-byom@sha256:$other"
if run deploy "$other" > "$tmp/result" 2>&1; then exit 1; fi
run start > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
run stop
run stop
diff -r "$tmp/staged" "$tmp/provider"
if MOCK_OWNER=someone-else run destroy > "$tmp/result" 2>&1; then exit 1; fi
if MOCK_PULL_FAIL=1 run deploy "$other" > "$tmp/result" 2>&1; then exit 1; fi
diff -r "$tmp/staged" "$tmp/provider"
run deploy "$other" > "$tmp/result"
grep -Fq "BYOM_IMAGE=$other" "$tmp/provider/env"
cat > "$tmp/bin/sleep" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/sleep"
if MOCK_VERIFY_FAIL=1 run start > "$tmp/result" 2>&1; then exit 1; fi
if grep -q '^PASSWORD=' "$tmp/result"; then exit 1; fi
run stop
run destroy
[[ -z $(ls -A "$tmp/provider") && -s "$tmp/key" ]]
echo 'Hetzner deploy/destroy and start/stop pairs passed.'
