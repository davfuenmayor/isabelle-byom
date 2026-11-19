#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
app=isabelle-byom token_file=''
usage() { echo 'Usage: ./byom diagnose fly [--app NAME] [--token FILE]' >&2; exit "${1:-1}"; }
while (($#)); do
  case "$1" in
    -h|--help) usage 0 2>&1 ;;
    --app|--token)
      (($# >= 2)) || usage
      case "$1" in --app) app=$2 ;; --token) token_file=$2 ;; esac
      shift 2 ;;
    *) usage ;;
  esac
done
[[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage
require_commands fly
FLY_API_TOKEN=$(read_token "$token_file" "${FLY_API_TOKEN:-}" 'Fly app deploy token')
export FLY_API_TOKEN
echo "Checking Fly app $app..."
fly status --app "$app" 2>&1
machines=$(fly machine list --app "$app" --json)
if [[ ! "$machines" =~ \"state\"[[:space:]]*:[[:space:]]*\"started\" ]]; then
  echo "FAIL: No running Machine. Start the existing Machine with: fly machine start MACHINE_ID --app $app" >&2
  exit 1
fi
echo 'Checking recent Machine failures...'
logs=$(fly logs --no-tail --app "$app" 2>&1)
had_oom=false
while IFS= read -r line; do
  if [[ "$line" == *'OOM killed'* || "$line" == *'Out of memory'* ]]; then
    printf '%s\n' "$line"
    had_oom=true
  fi
done <<< "$logs"
if $had_oom; then
  echo 'WARNING: Recent out-of-memory termination. Restarts change the server password; check the JVM budget against Machine RAM.'
fi
echo 'Checking public IP allocation...'
fly ips list --app "$app" 2>&1
# Stream the checks to the installed image; no redeployment or SDK is needed.
fly ssh console --app "$app" -C "bash -s -- wss://$app.fly.dev/isabelle" < "$root/server/diagnose.sh" 2>&1
