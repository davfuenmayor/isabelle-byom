#!/usr/bin/env bash
# Exercise the real entry point with a fake provider CLI; no cloud operations.
set -euo pipefail
root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/fly" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FLY_API_TOKEN" == 'FlyV1 test-token' ]]
if [[ ${MOCK_FAIL:-} == "$1" && "$1" != deploy && "$1" != ssh ]]; then exit 42; fi
printf '%s\n' "$@" >> "$MOCK_LOG"
case "$1 $2" in
  'status --app') echo '{}' ;;
  'ips list') echo '[{"Type":"v6"},{"Type":"shared_v4"}]' ;;
  'ssh console')
    echo 'Verifying public endpoint' >&2
    printf 'URL=wss://isabelle-byom.fly.dev/isabelle\nPASSWORD=test-password\n'
    [[ ${MOCK_FAIL:-} != ssh ]] || exit 42
    ;;
  'deploy '*)
    echo 'Building image'
    echo 'Uploading image' >&2
    [[ ${MOCK_FAIL:-} != deploy ]] || exit 42
    context=$2
    shift 2
    config=''
    while (($#)); do
      case "$1" in --config) config=$2; break ;; esac
      shift
    done
    [[ "$config" == "$context/providers/fly/fly.toml" ]]
    [[ -f "$(dirname "$config")/../../server/Dockerfile" ]]
    [[ -f "$context/server/component/src/byom.scala" ]]
    ;;
esac
MOCK
chmod +x "$tmp/bin/fly"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls"
printf 'FlyV1 test-token\n' > "$tmp/token with spaces"
# The explicit file overrides an inherited token, including an invalid one.
FLY_API_TOKEN=invalid "$root/byom" fly --region ams --token "$tmp/token with spaces" > "$tmp/result" 2> "$tmp/errors"
expected=$'=== Isabelle server credentials ===\nURL=wss://isabelle-byom.fly.dev/isabelle\nPASSWORD=test-password\n==================================='
[[ $(cat "$tmp/result") == *"$expected" ]]
[[ $(grep -c '^PASSWORD=' "$tmp/result") == 1 ]]
[[ $(cat "$tmp/result") == *$'Building image\nUploading image'* ]]
[[ $(cat "$tmp/result") == *$'Verifying public endpoint\n\n=== Isabelle server credentials ==='* ]]
[[ ! -s "$tmp/errors" ]]
[[ $(cat "$MOCK_LOG") == *$'--primary-region\nams'* ]]
[[ $(cat "$MOCK_LOG") == *$'--app\nisabelle-byom'* ]]
# An environment token and default app must work without stdin or a prompt.
FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly < /dev/null > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
# A missing or empty environment value falls back to the token prompt.
printf 'FlyV1 test-token\n' | (unset FLY_API_TOKEN; exec "$root/byom" fly) > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
printf 'FlyV1 test-token\n' | FLY_API_TOKEN='' "$root/byom" fly > "$tmp/result"
[[ $(cat "$tmp/result") == *"$expected" ]]
# Custom names remain available through --app.
: > "$MOCK_LOG"
FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly --app custom-instance < /dev/null > "$tmp/result"
[[ $(cat "$MOCK_LOG") == *$'--app\ncustom-instance'* ]]
if MOCK_FAIL=status "$root/byom" fly --token "$tmp/token with spaces" > "$tmp/result"; then
  echo 'Provider failure was ignored' >&2; exit 1
fi
[[ ! -s "$tmp/result" ]]
# Progress remains on stdout after failure; credentials never appear on failure.
for failure in deploy ssh; do
  if MOCK_FAIL="$failure" "$root/byom" fly --token "$tmp/token with spaces" > "$tmp/result"; then
    echo 'Deployment failure was ignored' >&2; exit 1
  fi
  [[ $(cat "$tmp/result") == *'Building image'* ]]
  [[ $(cat "$tmp/result") != *'PASSWORD='* && $(cat "$tmp/result") != *'=== Isabelle server credentials ==='* ]]
done
# Invalid environment values are rejected before invoking the provider CLI.
: > "$MOCK_LOG"
if FLY_API_TOKEN=invalid "$root/byom" fly < /dev/null > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" && ! -s "$MOCK_LOG" ]]
if "$root/byom" ../fly > "$tmp/result" 2>/dev/null; then
  echo 'Unknown provider was accepted' >&2; exit 1
fi
"$root/byom" --help > "$tmp/result"
[[ $(cat "$tmp/result") == *'Usage: ./byom PROVIDER [OPTIONS]'* ]]
"$root/byom" fly --help > "$tmp/result"
[[ $(cat "$tmp/result") == *'--token'* ]]
: > "$tmp/empty-token"
if FLY_API_TOKEN='FlyV1 test-token' "$root/byom" fly --token "$tmp/empty-token" > "$tmp/result" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/result" ]]
echo 'Deployment dispatch, token precedence, defaults, prompts and failure handling passed.'
