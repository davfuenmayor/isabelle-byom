#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ssh.sh
source "$root/providers/hetzner/ssh.sh"
name=isabelle-byom token_file='' key_file='' hostname='' sslip=false
usage() { echo 'Usage: ./byom diagnose hetzner (--sslip | --hostname HOST) [--name NAME] [--token FILE] [--ssh-key-file PATH]' >&2; exit "${1:-1}"; }
while (($#)); do
  case "$1" in
    -h|--help) usage 0 2>&1 ;;
    --sslip) sslip=true; shift ;;
    --name|--token|--ssh-key-file|--hostname)
      (($# >= 2)) || usage
      case "$1" in --name) name=$2 ;; --token) token_file=$2 ;; --ssh-key-file) key_file=$2 ;; --hostname) hostname=$2 ;; esac
      shift 2 ;;
    *) usage ;;
  esac
done
[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || usage
if $sslip; then [[ -z "$hostname" ]] || usage
else [[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]+$ ]] || usage; fi
require_commands hcloud ssh
HCLOUD_TOKEN=$(read_token "$token_file" "${HCLOUD_TOKEN:-}" 'Hetzner project Read & Write token')
export HCLOUD_TOKEN
echo "Checking Hetzner server $name..."
hcloud server describe "$name" 2>&1
state=$(hcloud server describe "$name" -o 'format={{.Status}}')
[[ "$state" == running ]] || { echo "FAIL: Server is $state. Start it with: hcloud server poweron $name" >&2; exit 1; }
if $sslip; then
  ip=$(hcloud server describe "$name" -o 'format={{.PublicNet.IPv4.IP}}')
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'FAIL: No public IPv4.' >&2; exit 1; }
  hostname="$ip.sslip.io"
fi
key_file=${key_file:-$HOME/.ssh/isabelle-byom-$name}
[[ -f "$key_file" ]] || { echo "FAIL: Restore the existing deployment key: $key_file" >&2; exit 1; }
hetzner_ssh "$name" "$key_file" \
  "cd /opt/isabelle-byom/providers/hetzner && docker compose exec -T isabelle bash -s -- wss://$hostname/isabelle" \
  < "$root/server/diagnose.sh" 2>&1
