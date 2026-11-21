#!/usr/bin/env bash
set -euo pipefail
isabelle=${ISABELLE_TOOL:-/home/isabelle/Isabelle/bin/isabelle}
component=${BYOM_COMPONENT:-/opt/byom/component}
info=${BYOM_INFO:-/tmp/byom-server.info}
server_pid='' relay_pid='' runtime='' owns_info=false
pids=()
collect_tree() {
  local child
  while read -r child; do
    [[ -n "$child" ]] && collect_tree "$child"
  done < <(pgrep -P "$1" || true)
  pids+=("$1")
}
cleanup() {
  local status=$? pid running deadline
  trap - EXIT INT TERM
  for pid in "$relay_pid" "$server_pid"; do
    [[ -z "$pid" ]] || collect_tree "$pid"
  done
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  deadline=$((SECONDS + ${BYOM_STOP_TIMEOUT:-10}))
  while ((SECONDS < deadline)); do
    running=false
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then running=true; fi
    done
    $running || break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  wait || true
  if $owns_info; then rm -f "$info"; fi
  [[ -z "$runtime" ]] || rm -rf "$runtime"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
runtime=$(mktemp -d "${TMPDIR:-/tmp}/byom.XXXXXXXX")
export USER_HOME="$runtime"
user_dir=$(timeout --kill-after=2 "${BYOM_START_TIMEOUT:-120}" "$isabelle" getenv -b ISABELLE_HOME_USER)
config="$user_dir/etc"
mkdir -p "$config"
printf 'init_component "%s"\n' "$component" > "$config/settings"
if [[ -n ${BYOM_JAVA_OPTIONS:-} ]]; then
  printf 'ISABELLE_TOOL_JAVA_OPTIONS=%q\n' "$BYOM_JAVA_OPTIONS" >> "$config/settings"
fi
if [[ -n ${BYOM_THREADS:-} ]]; then
  [[ "$BYOM_THREADS" =~ ^[1-9][0-9]*$ ]] || { echo 'BYOM_THREADS must be positive' >&2; exit 1; }
  printf 'threads = %s\n' "$BYOM_THREADS" > "$config/preferences"
fi
[[ ! -L "$info" ]] || { echo 'Metadata path must not be a symbolic link' >&2; exit 1; }
: > "$info"
chmod 600 "$info"
owns_info=true
"$isabelle" server -n byom -p "${ISABELLE_SERVER_PORT:-8081}" > "$info" 2>&1 &
server_pid=$!
port=''
deadline=$((SECONDS + ${BYOM_START_TIMEOUT:-120}))
while ((SECONDS < deadline)); do
  kill -0 "$server_pid" 2>/dev/null || { echo 'Isabelle startup failed' >&2; exit 1; }
  port=$(sed -n 's/^server "[^"]*" = 127\.0\.0\.1:\([0-9]*\) (password "[^"]*").*/\1/p' "$info" | head -n1)
  [[ -z "$port" ]] || break
  sleep 0.1
done
if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port <= 0 || port > 65535)); then
  echo 'Isabelle startup timed out' >&2; exit 1
fi
websocat -b -E --restrict-uri /isabelle --ping-interval 20 --ping-timeout 60 \
  "ws-l:${BYOM_BIND_ADDRESS:-0.0.0.0}:${PORT:-8080}" "tcp:127.0.0.1:$port" &
relay_pid=$!
echo 'Isabelle BYOM ready'
wait -n "$server_pid" "$relay_pid"
