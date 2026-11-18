#!/usr/bin/env bash
# Linux runtime test: hostile children deliberately ignore TERM.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/work"
cat > "$tmp/bin/isabelle" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == getenv ]]; then
  if [[ ${FAIL_GETENV:-0} == 2 ]]; then
    trap '' TERM
    while :; do sleep 1; done
  fi
  [[ ${FAIL_GETENV:-0} == 0 ]] || exit 7
  echo "$USER_HOME/.isabelle"
  exit
fi
# Detached process groups must be stopped too.
setsid bash -c 'trap "" TERM; echo "$BASHPID" >> "$TEST_PIDS"; while :; do sleep 1; done' &
echo "$BASHPID" >> "$TEST_PIDS"
trap '' TERM
if [[ ${NO_METADATA:-0} == 0 ]]; then
  printf 'server "byom" = 127.0.0.1:23456 (password "test")\n'
fi
while :; do sleep 1; done
MOCK
cat > "$tmp/bin/websocat" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${!#} == tcp:127.0.0.1:23456 ]]
if [[ ${FAIL_RELAY:-0} == 1 ]]; then exit 9; fi
trap '' TERM
echo "$BASHPID" >> "$TEST_PIDS"
while :; do sleep 1; done
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" ISABELLE_TOOL="$tmp/bin/isabelle" BYOM_COMPONENT="$root/server/component"
export BYOM_STOP_TIMEOUT=1 BYOM_START_TIMEOUT=1 ISABELLE_SERVER_PORT=0
export TEST_PIDS="$tmp/pids" BYOM_INFO="$tmp/info" TMPDIR="$tmp/work"
for scenario in config config-hang timeout relay signal; do
  : > "$TEST_PIDS"
  export FAIL_GETENV=0 NO_METADATA=0 FAIL_RELAY=0
  case "$scenario" in config) export FAIL_GETENV=1 ;; config-hang) export FAIL_GETENV=2 ;; timeout) export NO_METADATA=1 ;; relay) export FAIL_RELAY=1 ;; esac
  started=$SECONDS
  "$root/server/start.sh" > "$tmp/log" 2>&1 &
  launcher=$!
  if [[ "$scenario" == signal ]]; then
    for ((i=0; i<100; i++)); do
      if grep -q 'BYOM ready' "$tmp/log"; then break; fi
      sleep 0.05
    done
    grep -q 'BYOM ready' "$tmp/log"
    kill -TERM "$launcher"
  fi
  status=0
  wait "$launcher" || status=$?
  ((status != 0 && SECONDS - started < 8))
  [[ ! -e "$BYOM_INFO" ]]
  [[ -z $(ls -A "$tmp/work") ]]
  while read -r pid; do
    # A terminated orphan may await container init's reaper; it cannot execute.
    state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
    [[ -z "$state" || "$state" == Z* ]]
  done < "$TEST_PIDS"
  echo "Bounded $scenario cleanup passed."
done
