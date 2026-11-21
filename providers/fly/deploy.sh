#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=exec.sh
source "$root/providers/fly/exec.sh"
app=isabelle-byom region=fra token_file='' instance='' action=start image=''
case "${1:-}" in deploy|start|stop|diagnose|destroy) action=$1; shift ;; esac
usage() {
  echo 'Usage: ./byom fly [deploy IMAGE|start|stop|diagnose|destroy] [--app NAME] [--instance ID] [--token FILE]'
  echo 'Deploy requires a pinned OCI image (NAME@sha256:DIGEST). Optional: --region REGION (default: fra).'
  echo 'Default app: isabelle-byom. Token: --token FILE, FLY_API_TOKEN, then prompt.'
  exit "${1:-1}"
}
if [[ $action == deploy && ${1:-} != -* ]]; then
  image=${1:-}
  is_pinned_image "$image" || usage >&2
  shift
fi
while (($#)); do
  case "$1" in
    -h|--help) usage 0 ;;
  esac
  (($# >= 2)) || usage >&2
  case "$1" in
    --app) app=$2 ;; --token) token_file=$2 ;; --instance) instance=$2 ;;
    --region) [[ $action == deploy ]] || usage >&2; region=$2 ;;
    *) usage >&2 ;;
  esac
  shift 2
done
[[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ && "$region" =~ ^[a-z]{3}$ ]] || usage >&2
[[ -z "$instance" || "$instance" =~ ^[a-z0-9]+$ ]] || usage >&2
if [[ $action == deploy ]]; then is_pinned_image "$image" || usage >&2; fi
require_commands fly jq
FLY_API_TOKEN=$(read_token "$token_file" "${FLY_API_TOKEN:-}" 'Fly app deploy token')
[[ "$FLY_API_TOKEN" == 'FlyV1 '* ]] || { echo 'Expected the whole FlyV1 token' >&2; exit 1; }
export FLY_API_TOKEN

select_machine() {
  machines=$(fly machine list --app "$app" --json)
  rows=$(jq -r 'if type == "array" or . == null then
    .[]? | select(.state != "destroyed" and .state != "destroying") |
    [.id, .state, (.cordoned // false), (.config.metadata.isabelle_byom // "false"),
      (.config.metadata.isabelle_byom_release // .image_ref.digest // "-"),
      (any(.config.services[]?; .autostart != false))] | @tsv
    else error("Expected Fly Machine list") end' <<< "$machines")
  if [[ -n "$instance" ]]; then
    row=$(awk -v id="$instance" '$1 == id' <<< "$rows")
    if [[ -z "$row" && $action != stop && $action != destroy ]]; then
      echo "Machine $instance was not found in $app." >&2
      exit 1
    fi
  elif [[ "$rows" == *$'\n'* ]]; then
    echo "Choose a Machine in $app with --instance ID. IDs and states:" >&2
    printf '%s\n' "$rows" >&2
    exit 1
  else
    row=$rows
  fi
  read -r machine state cordoned owned digest autostart <<< "$row"
}

public_route() {
  if awk -v id="$machine" '$1 != id && $3 == "false" {found=1} END {exit !found}' <<< "$rows"; then
    echo "The public URL for $app is shared by multiple Machines. Stop the other Machines first." >&2
    exit 1
  fi
}

wait_for_staging() {
  [[ "$state" == created ]] || return 0
  local target=$machine deadline=$((SECONDS + 180))
  echo "Waiting for Fly to prepare Machine $target..."
  while [[ "$state" == created ]]; do
    if ((SECONDS >= deadline)); then
      echo "Machine $target is still preparing. Retry once Fly reports it stopped." >&2
      return 1
    fi
    sleep 2
    select_machine
    [[ "$machine" == "$target" ]] || { echo "Machine $target disappeared during staging." >&2; return 1; }
  done
}

select_machine
case "$action" in
  deploy)
    release_digest=${image##*@}
    if [[ -z "$machine" ]]; then
      fly machine create "$image" --app "$app" --name isabelle-byom --region "$region" --autostart=false \
        --machine-config "$root/providers/fly/machine.json" --metadata "isabelle_byom_release=$release_digest" 2>&1
      select_machine
      [[ -n "$machine" ]] || { echo "No Machine found after creation in $app." >&2; exit 1; }
    elif [[ "$owned" != true ]]; then
      echo "Machine $machine predates this deployment API. Keep using start/stop, or migrate it before deploying." >&2
      exit 1
    elif [[ "$digest" != "$release_digest" ]]; then
      [[ "$state" == stopped || "$state" == created || "$state" == suspended ]] ||
        { echo "Stop Machine $machine before changing its release." >&2; exit 1; }
      wait_for_staging
      fly machine update "$machine" --app "$app" --image "$image" --skip-start --yes \
        --metadata "isabelle_byom_release=$release_digest" 2>&1
      select_machine
    fi
    wait_for_staging
    echo "Release staged in $app."
    exit 0
    ;;
  destroy)
    if [[ -z "$machine" ]]; then echo "No matching Machine in $app."; exit 0; fi
    [[ "$owned" == true ]] || { echo "Machine $machine is outside BYOM deployment ownership." >&2; exit 1; }
    [[ "$state" == stopped || "$state" == created || "$state" == suspended ]] ||
      { echo "Stop Machine $machine before destroying the deployment." >&2; exit 1; }
    if [[ "$state" == created ]]; then
      fly machine destroy "$machine" --app "$app" --force
    else
      fly machine destroy "$machine" --app "$app"
    fi
    exit 0
    ;;
  stop)
    if [[ -z "$machine" ]]; then echo "No matching Machine in $app."; exit 0; fi
    if [[ "$cordoned" != true && ( "$owned" != true || "$autostart" == true ) ]]; then
      fly machine cordon "$machine" --app "$app"
    fi
    case "$state" in
      stopped|suspended|created) ;;
      stopping) fly machine wait "$machine" --app "$app" --state stopped --wait-timeout 1m ;;
      *) fly machine stop "$machine" --app "$app" --signal SIGTERM --timeout 30 --wait-timeout 1m ;;
    esac
    echo "Stopped Fly Machine $machine in $app."
    exit 0
    ;;
esac

[[ -n "$machine" ]] || { echo "No Machine installed in $app. Run ./byom fly deploy IMAGE." >&2; exit 1; }
if [[ $action == start ]]; then
  public_route
  echo "Fly Machine $machine in $app is $state."
  wait_for_staging
  case "$state" in
    started) ;;
    starting) fly machine wait "$machine" --app "$app" --state started 2>&1 ;;
    stopped|suspended) fly machine start "$machine" --app "$app" --wait 2>&1 ;;
    *) echo "Machine $machine is $state. Try again when its state settles." >&2; exit 1 ;;
  esac
  if [[ "$cordoned" == true ]]; then fly machine uncordon "$machine" --app "$app" 2>&1; fi
else
  echo "Fly Machine $machine in $app is $state."
  if [[ "$state" != started || "$cordoned" == true ]]; then
    echo 'FAIL: Machine is unavailable. Run ./byom fly start.' >&2
    exit 1
  fi
  public_route
fi

url="wss://$app.fly.dev/isabelle"
if [[ $action == diagnose ]]; then
  echo 'Checking Machine logs for out-of-memory failures...'
  logs=$(fly logs --no-tail --app "$app" --instance "$machine" 2>&1)
  if grep -E 'OOM killed|Out of memory' <<< "$logs"; then
    echo 'WARNING: Fly logs record an out-of-memory termination. Restarts change the server password.'
  fi
  echo 'Checking public IP allocation...'
  fly ips list --app "$app" 2>&1
  script=$(base64 < "$root/server/diagnose.sh" | tr -d '\n')
  fly_exec "$app" "$machine" 30 "bash -c 'printf %s $script | base64 -d | bash -s -- $url'" 2>&1
else
  exec 3>&1
  if ! credentials=$(fly_exec "$app" "$machine" 135 "/opt/byom/credentials.sh $url" 2>&3); then
    echo 'Public WSS verification failed. Run ./byom fly diagnose with the same app and token.' >&2
    exit 1
  fi
  print_credentials "$credentials"
fi
