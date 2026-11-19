#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
app=isabelle-byom region=fra token_file=''
usage() {
  echo 'Usage: ./byom fly [--app NAME] [--region REGION] [--token FILE]' >&2
  echo 'Default app: isabelle-byom; region: fra. Token: --token FILE, FLY_API_TOKEN, then prompt.' >&2
  exit "${1:-1}"
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage 0 2>&1; fi
while (($#)); do
  (($# >= 2)) || usage
  case "$1" in
    --app) app=$2 ;;
    --region) region=$2 ;;
    --token) token_file=$2 ;;
    *) usage ;;
  esac
  shift 2
done
require_commands fly
[[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo 'Invalid Fly app name' >&2; exit 1; }
[[ "$region" =~ ^[a-z]{3}$ ]] || { echo 'Invalid Fly region' >&2; exit 1; }
FLY_API_TOKEN=$(read_token "$token_file" "${FLY_API_TOKEN:-}" 'Fly app deploy token')
[[ "$FLY_API_TOKEN" == 'FlyV1 '* ]] || { echo 'Expected the whole FlyV1 token' >&2; exit 1; }
export FLY_API_TOKEN
fly status --app "$app" --json >/dev/null
fly deploy "$root" --config "$root/providers/fly/fly.toml" --app "$app" \
  --primary-region "$region" --remote-only --ha=false --yes --wait-timeout 10m 2>&1
ips=$(fly ips list --app "$app" --json)
if [[ "$ips" != *'"v6"'* ]]; then fly ips allocate-v6 --app "$app" 2>&1; fi
if [[ "$ips" != *'"shared_v4"'* ]]; then fly ips allocate-v4 --shared --app "$app" 2>&1; fi
# Route SSH progress to stdout while buffering the verified credentials.
exec 3>&1
credentials=$(fly ssh console --app "$app" -C "/opt/byom/credentials.sh wss://$app.fly.dev/isabelle" 2>&3)
print_credentials "$credentials"
