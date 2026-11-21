#!/usr/bin/env bash
# Boot EXISTING resources only. Restore stopped state when this test started it.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../providers/fly/exec.sh
source "$root/providers/fly/exec.sh"
provider=${1:?Usage: boot.sh fly APP MACHINE_ID | hetzner SERVER SSH_KEY HOSTNAME}
resource=${2:?Existing app/server required}
tmp=$(mktemp -d)
started=false uncordoned=false
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if $uncordoned; then
    fly machine cordon "$machine" --app "$resource" >&2 || status=1
  fi
  if $started; then
    case "$provider" in
      fly) fly machine stop "$machine" --app "$resource" --signal SIGTERM --wait-timeout 1m >&2 || status=1 ;;
      hetzner) hcloud server shutdown "$resource" --wait >&2 || status=1 ;;
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
    details=$(fly machine list --app "$resource" --json | jq -ce --arg id "$machine" '.[] | select(.id == $id)')
    state=$(jq -er .state <<< "$details")
    if [[ "$state" == stopped ]]; then started=true; fly machine start "$machine" --app "$resource" >&2
    else [[ "$state" == started ]]; fi
    if jq -e '.cordoned == true' <<< "$details" >/dev/null; then
      uncordoned=true
      fly machine uncordon "$machine" --app "$resource" >&2
    fi
    fly_exec "$resource" "$machine" 135 "/opt/byom/credentials.sh wss://$resource.fly.dev/isabelle" > "$tmp/credentials"
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
ISABELLE_PASSWORD=incorrect ISABELLE_TEST_REJECT_AUTH=1 bash "$root/test/protocol.sh"
echo "$provider boot, public TLS, current credentials and protocol checks passed."
