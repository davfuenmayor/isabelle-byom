#!/usr/bin/env bash
# Exercise the real entry point with a stateful fake Fly CLI.
set -euo pipefail
root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/provider"
cat > "$tmp/bin/fly" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FLY_API_TOKEN" == 'FlyV1 test-token' ]]
printf '%s\n' "$@" >> "$MOCK_LOG"
file="$MOCK_PROVIDER/machine"
case "$1 $2" in
  'machine list')
    if [[ -n ${MOCK_MACHINES:-} ]]; then echo "$MOCK_MACHINES"
    elif [[ -f "$file" ]]; then
      jq -s . "$file"
      if [[ $(jq -r .state "$file") == created ]]; then
        jq '.state="stopped"' "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
      fi
    else echo '[]'; fi ;;
  'machine create')
    [[ ${MOCK_FAIL:-} != create ]] || { echo 'Image preparation failed'; exit 42; }
    config=${@: -3:1}
    [[ ${!#} == "isabelle_byom_release=${3##*@}" ]]
    jq -e '.services[0].autostart == false and .guest.memory_mb == 4096' "$config" >/dev/null
    jq --arg digest "${3##*@}" '
      .metadata.isabelle_byom_release=$digest |
      {id:"abc1",state:"created",config:.,image_ref:{digest:"resolved-platform-digest"}}
    ' "$config" > "$file" ;;
  'machine update')
    [[ "$*" == *--skip-start* ]]
    image=$7
    [[ ${!#} == "isabelle_byom_release=${image##*@}" ]]
    jq --arg digest "${image##*@}" '.config.metadata.isabelle_byom_release=$digest' "$file" > "$file.tmp"
    mv "$file.tmp" "$file" ;;
  'machine start'|'machine stop')
    if [[ -f "$file" ]]; then
      next=started
      if [[ "$2" == stop ]]; then
        next=stopped
      else
        [[ $(jq -r .state "$file") == stopped ]]
      fi
      jq --arg state "$next" '.state=$state' "$file" > "$file.tmp"
      mv "$file.tmp" "$file"
    fi ;;
  'machine destroy')
    if [[ $(jq -r .state "$file") == created ]]; then [[ "$*" == *--force* ]]; fi
    rm "$file" ;;
  'machine cordon'|'machine uncordon') : ;;
  'machine exec')
    code=0
    if [[ ${MOCK_FAIL:-} == exec ]]; then code=42; fi
    printf '{"stdout":"URL=wss://isabelle-byom.fly.dev/isabelle\\nPASSWORD=test-password\\n","stderr":"Verifying public endpoint\\n","exit_code":%d}\n' "$code" ;;
  *) echo "Unexpected command: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/sleep" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/fly" "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls" MOCK_PROVIDER="$tmp/provider"
printf 'FlyV1 test-token\n' > "$tmp/token with spaces"
export FLY_API_TOKEN='FlyV1 test-token'
printf 'operator-owned\n' > "$MOCK_PROVIDER/app"
cp -R "$MOCK_PROVIDER" "$tmp/before"
printf -v digest '%064d' 1
image="registry.example.org/isabelle-byom@sha256:$digest"
expected=$'=== Isabelle server credentials ===\nURL=wss://isabelle-byom.fly.dev/isabelle\nPASSWORD=test-password\n==================================='

if "$root/byom" fly start > "$tmp/result" 2>&1; then exit 1; fi
if MOCK_FAIL=create "$root/byom" fly deploy "$image" > "$tmp/result" 2>&1; then exit 1; fi
diff -r "$tmp/before" "$MOCK_PROVIDER"

# Deploy/destroy alone should return the app to its original state.
FLY_API_TOKEN=invalid "$root/byom" fly deploy "$image" --region ams --token "$tmp/token with spaces" > "$tmp/result"
grep -Fxq ams "$MOCK_LOG"
grep -Fxq create "$MOCK_LOG"
grep -Fq 'Waiting for Fly to prepare Machine' "$tmp/result"
jq -e '.state == "stopped"' "$MOCK_PROVIDER/machine" >/dev/null
if grep -q '^PASSWORD=' "$tmp/result"; then exit 1; fi
"$root/byom" fly destroy
"$root/byom" fly destroy
diff -r "$tmp/before" "$MOCK_PROVIDER"

# Start/stop preserves the staged image, networking configuration and ownership.
"$root/byom" fly deploy "$image"
cp "$MOCK_PROVIDER/machine" "$tmp/staged"
: > "$MOCK_LOG"
"$root/byom" fly deploy "$image"
if grep -Eq '^(create|update|start)$' "$MOCK_LOG"; then exit 1; fi
# A start can also encounter a Machine from an interrupted deployment.
jq '.state="created"' "$MOCK_PROVIDER/machine" > "$tmp/preparing"
mv "$tmp/preparing" "$MOCK_PROVIDER/machine"
"$root/byom" fly start > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
jq -e '.state == "started"' "$MOCK_PROVIDER/machine" >/dev/null
if "$root/byom" fly destroy > "$tmp/result" 2>&1; then exit 1; fi
printf -v other_digest '%064d' 2
if "$root/byom" fly deploy "registry.example.org/isabelle-byom@sha256:$other_digest" > "$tmp/result" 2>&1; then exit 1; fi
: > "$MOCK_LOG"
"$root/byom" fly start >/dev/null
if grep -Eq '^(create|update|start)$' "$MOCK_LOG"; then exit 1; fi
"$root/byom" fly stop
"$root/byom" fly stop
jq -e '.state == "stopped"' "$MOCK_PROVIDER/machine" >/dev/null
diff "$tmp/staged" "$MOCK_PROVIDER/machine"
[[ $(grep -Fxc stop "$MOCK_LOG") == 1 ]]
if grep -Eq '^(cordon|uncordon)$' "$MOCK_LOG"; then exit 1; fi
"$root/byom" fly deploy "registry.example.org/isabelle-byom@sha256:$other_digest"
jq -e --arg digest "sha256:$other_digest" '.state == "stopped" and .config.metadata.isabelle_byom_release == $digest' "$MOCK_PROVIDER/machine" >/dev/null
if MOCK_FAIL='exec' "$root/byom" fly start > "$tmp/result" 2>&1; then exit 1; fi
if grep -q '^PASSWORD=' "$tmp/result"; then exit 1; fi
# A missing or empty environment value falls back to the token prompt.
printf 'FlyV1 test-token\n' | (unset FLY_API_TOKEN; exec "$root/byom" fly) > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
printf 'FlyV1 test-token\n' | FLY_API_TOKEN='' "$root/byom" fly > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
# Custom names remain available through --app.
: > "$MOCK_LOG"
FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly --app custom-instance < /dev/null > "$tmp/result"
[[ $(cat "$MOCK_LOG") == *$'--app\ncustom-instance'* ]]
# Existing deployments still support ordinary lifecycle commands.
: > "$MOCK_LOG"
MOCK_MACHINES='[{"id":"abc2","state":"started"}]' "$root/byom" fly stop --instance abc2
[[ $(cat "$MOCK_LOG") == *$'cordon\nabc2\n'*'stop'$'\nabc2\n'* ]]
if MOCK_MACHINES='[{"id":"abc2","state":"stopped"}]' "$root/byom" fly destroy --instance abc2 > "$tmp/result" 2>&1; then exit 1; fi
"$root/byom" fly stop
"$root/byom" fly destroy
diff -r "$tmp/before" "$MOCK_PROVIDER"

# Invalid environment values are rejected before invoking the provider CLI.
: > "$MOCK_LOG"
if FLY_API_TOKEN=invalid "$root/byom" fly < /dev/null > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" && ! -s "$MOCK_LOG" ]]
if "$root/byom" ../fly > "$tmp/result" 2>/dev/null; then
  echo 'Unknown provider was accepted' >&2; exit 1
fi
"$root/byom" --help > "$tmp/result"
[[ $(cat "$tmp/result") == *'Usage: ./byom PROVIDER [deploy|start|stop|diagnose|destroy]'* ]]
for provider in fly hetzner hpc; do
  if "$root/byom" "$provider" connect < /dev/null > "$tmp/result" 2>&1; then exit 1; fi
  grep -Fq "Usage: ./byom $provider " "$tmp/result"
done
"$root/byom" fly --help > "$tmp/result"
[[ $(cat "$tmp/result") == *'--token'* ]]
: > "$tmp/empty-token"
if FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly --token "$tmp/empty-token" > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" ]]
echo 'Deployment dispatch, token precedence, defaults, prompts and failure handling passed.'
