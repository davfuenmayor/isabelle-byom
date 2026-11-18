#!/usr/bin/env bash
# Boot EXISTING resources only. Restore stopped state when this test started it.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider=${1:?Usage: boot.sh fly APP MACHINE_ID | hetzner SERVER SSH_KEY HOSTNAME}
resource=${2:?Existing app/server required}
tmp=$(mktemp -d)
started=false
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if $started; then
    case "$provider" in
      fly) fly machine stop "$machine" --app "$resource" >&2 ;;
      hetzner) hcloud server shutdown "$resource" >&2 ;;
    esac
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$provider" in
  fly)
    machine=${3:?Existing Machine ID required}
    state=$(fly machine status "$machine" --app "$resource" --json | jq -er .state)
    if [[ "$state" == stopped ]]; then started=true; fly machine start "$machine" --app "$resource" >&2
    else [[ "$state" == started ]]; fi
    fly ssh console --app "$resource" --machine "$machine" -C "/opt/byom/credentials.sh wss://$resource.fly.dev/isabelle" > "$tmp/credentials"
    ;;
  hetzner)
    key=${3:?Existing deployment SSH key required}
    hostname=${4:?Public TLS hostname required}
    state=$(hcloud server describe "$resource" -o 'format={{.Status}}')
    if [[ "$state" == off ]]; then started=true; hcloud server poweron "$resource" >&2
    else [[ "$state" == running ]]; fi
    ready=false
    for ((attempt=0; attempt<60; attempt++)); do
      if hcloud server ssh "$resource" -i "$key" -o BatchMode=yes -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$key.known_hosts" \
          "cd /opt/isabelle-byom/providers/hetzner && docker compose exec -T isabelle /opt/byom/credentials.sh wss://$hostname/isabelle" > "$tmp/credentials"; then ready=true; break; fi
      sleep 2
    done
    $ready
    ;;
  *) echo 'Supported boot tests: fly, hetzner' >&2; exit 1 ;;
esac
ISABELLE_URL=$(sed -n 's/^URL=//p' "$tmp/credentials")
ISABELLE_PASSWORD=$(sed -n 's/^PASSWORD=//p' "$tmp/credentials")
export ISABELLE_URL ISABELLE_PASSWORD
bash "$root/test/protocol.sh"
if ISABELLE_PASSWORD=incorrect bash "$root/test/protocol.sh" > "$tmp/rejected" 2>&1; then
  echo 'Invalid password was accepted' >&2; exit 1
fi
echo "$provider boot, public TLS, current credentials and protocol checks passed."
