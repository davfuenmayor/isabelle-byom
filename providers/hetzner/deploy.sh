#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
name=isabelle-byom location=fsn1 type=cx23 token_file='' key_file='' hostname='' sslip=false
usage() {
  echo 'Usage: ./byom hetzner (--sslip | --hostname HOST) [--name NAME] [--location fsn1] [--type cx23] [--token FILE] [--ssh-key-file PATH]' >&2
  echo 'Token: --token FILE, HCLOUD_TOKEN, then prompt.' >&2
  exit "${1:-1}"
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage 0 2>&1; fi
while (($#)); do
  if [[ $1 == --sslip ]]; then sslip=true; shift; continue; fi
  (($# >= 2)) || usage
  case "$1" in
    --name) name=$2 ;; --location) location=$2 ;; --type) type=$2 ;;
    --token) token_file=$2 ;; --ssh-key-file) key_file=$2 ;;
    --hostname) hostname=$2 ;; *) usage ;;
  esac
  shift 2
done
[[ "$name" =~ ^[a-z][a-z0-9-]*$ && "$location" =~ ^[a-z0-9]+$ && "$type" =~ ^[a-z0-9]+$ ]] || usage
if $sslip; then [[ -z "$hostname" ]] || usage
else [[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]+$ ]] || usage; fi
require_commands hcloud ssh ssh-keygen tar
if [[ -n "$token_file" ]]; then
  HCLOUD_TOKEN=$(read_token "$token_file" "Hetzner project Read & Write token")
elif [[ -z ${HCLOUD_TOKEN:-} ]]; then
  HCLOUD_TOKEN=$(read_token "" "Hetzner project Read & Write token")
fi
export HCLOUD_TOKEN
# Authenticate before creating local keys or cloud resources.
servers=$(hcloud server list -o noheader -o columns=name)
exists=false
if [[ $'\n'"$servers"$'\n' == *$'\n'"$name"$'\n'* ]]; then
  exists=true
  owner=$(hcloud server describe "$name" -o 'format={{index .Labels "isabelle-byom"}}')
  [[ "$owner" == "$name" ]] || { echo "Refusing to overwrite unowned server: $name" >&2; exit 1; }
fi
architecture=$(hcloud server-type describe "$type" -o 'format={{.Architecture}}')
[[ "$architecture" == x86 ]] || { echo 'The shared image currently requires an x86 server type' >&2; exit 1; }
key_file=${key_file:-$HOME/.ssh/isabelle-byom-$name}
mkdir -p "$(dirname "$key_file")"
if [[ ! -f "$key_file" ]]; then ssh-keygen -q -t ed25519 -N '' -f "$key_file"; fi
public_key=$(ssh-keygen -y -f "$key_file")
key_name="byom-$name"
keys=$(hcloud ssh-key list -o noheader -o columns=name)
if [[ $'\n'"$keys"$'\n' == *$'\n'"$key_name"$'\n'* ]]; then
  existing=$(hcloud ssh-key describe "$key_name" -o 'format={{.PublicKey}}')
  [[ "$existing" == "$public_key" ]] || { echo "SSH key $key_name already exists with different material" >&2; exit 1; }
else hcloud ssh-key create --name "$key_name" --public-key "$public_key" 2>&1; fi
firewalls=$(hcloud firewall list -o noheader -o columns=name)
if [[ $'\n'"$firewalls"$'\n' != *$'\n'"$key_name"$'\n'* ]]; then
  hcloud firewall create --name "$key_name" --rules-file "$root/providers/hetzner/firewall.json" 2>&1
fi
if ! $exists; then
  hcloud server create --name "$name" --location "$location" --type "$type" --image ubuntu-24.04 \
    --ssh-key "$key_name" --firewall "$key_name" --label "isabelle-byom=$name" 2>&1
fi
if ! result=$(hcloud firewall apply-to-resource "$key_name" --type server --server "$name" 2>&1); then
  [[ "$result" == *firewall_already_applied* ]] || { echo "$result" >&2; exit 1; }
fi
ip=$(hcloud server describe "$name" -o 'format={{.PublicNet.IPv4.IP}}')
[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Server has no public IPv4' >&2; exit 1; }
if $sslip; then hostname="$ip.sslip.io"; fi
echo "Server: $name ($ip); HTTPS hostname: $hostname"
remote() {
  hcloud server ssh "$name" -i "$key_file" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$key_file.known_hosts" "$@"
}
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if remote true 2>/dev/null; then ready=true; break; fi
  sleep 2
done
$ready || { echo 'SSH startup timed out; resources remain for diagnosis' >&2; exit 1; }
remote 'mkdir -p /opt/isabelle-byom' 2>&1
# Explicit build inputs: credentials, generated JARs and notebook files stay local.
tar -C "$root" -cf - .dockerignore server/Dockerfile server/start.sh server/credentials.sh \
  server/component/etc server/component/src providers/hetzner/compose.yaml \
  providers/hetzner/Caddyfile providers/hetzner/bootstrap.sh |
  remote 'tar -xf - -C /opt/isabelle-byom' 2>&1
remote 'bash /opt/isabelle-byom/providers/hetzner/bootstrap.sh' 2>&1
if ! $sslip; then echo "Point $hostname A record to $ip before certificate issuance."; fi
remote "cd /opt/isabelle-byom/providers/hetzner && printf '%s\\n' 'BYOM_HOST=$hostname' > .env && docker compose up -d --build" 2>&1
# Keep SSH progress on stdout while buffering credentials until verification succeeds.
exec 3>&1
for ((attempt=0; attempt<12; attempt++)); do
  if credentials=$(remote "cd /opt/isabelle-byom/providers/hetzner && docker compose exec -T isabelle /opt/byom/credentials.sh wss://$hostname/isabelle" 2>&3); then
    print_credentials "$credentials"
    exit 0
  fi
  sleep 5
done
echo 'Public WSS verification failed; inspect Docker/Caddy logs. Server retained for diagnosis.' >&2
exit 1
