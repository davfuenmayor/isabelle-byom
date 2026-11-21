#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$root/providers/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=ssh.sh
source "$root/providers/hetzner/ssh.sh"
name=isabelle-byom location=fsn1 type=cx23 token_file='' key_file='' hostname='' sslip=false action=start image=''
case "${1:-}" in deploy|start|stop|diagnose|destroy) action=$1; shift ;; esac
usage() {
  echo 'Usage: ./byom hetzner [deploy IMAGE|start|stop|diagnose|destroy] [--name NAME] [--token FILE] [--ssh-key-file PATH]' >&2
  echo 'Deploy requires a pinned OCI image (NAME@sha256:DIGEST). Options: --sslip or --hostname HOST, --location, --type.' >&2
  echo 'Token: --token FILE, HCLOUD_TOKEN, then prompt.' >&2
  exit "${1:-1}"
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage 0 2>&1; fi
if [[ $action == deploy && ${1:-} != -* ]]; then
  image=${1:-}
  is_pinned_image "$image" || usage
  shift
fi
while (($#)); do
  case "$1" in
    --sslip) sslip=true; shift; continue ;;
  esac
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
elif [[ -n "$hostname" ]]; then [[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]+$ ]] || usage; fi
if [[ $action == deploy ]]; then is_pinned_image "$image" || usage; fi
require_commands hcloud
HCLOUD_TOKEN=$(read_token "$token_file" "${HCLOUD_TOKEN:-}" 'Hetzner project Read & Write token')
export HCLOUD_TOKEN
# Authenticate before creating local keys or cloud resources.
servers=$(hcloud server list -o noheader -o columns=name)
exists=false
state=absent
key_name="byom-$name"
if [[ $'\n'"$servers"$'\n' == *$'\n'"$name"$'\n'* ]]; then
  exists=true
  owner=$(hcloud server describe "$name" -o 'format={{index .Labels "isabelle-byom"}}')
  [[ "$owner" == "$name" ]] || { echo "Refusing to manage unowned server: $name" >&2; exit 1; }
  state=$(hcloud server describe "$name" -o 'format={{.Status}}')
fi
if [[ $action == destroy ]]; then
  if $exists; then
    [[ "$state" == off ]] || { echo "Stop $name before destroying the deployment." >&2; exit 1; }
    hcloud server delete "$name"
  fi
  for resource in firewall ssh-key; do
    names=$(hcloud "$resource" list -l "isabelle-byom=$name" -o noheader -o columns=name)
    if [[ $'\n'"$names"$'\n' == *$'\n'"$key_name"$'\n'* ]]; then
      hcloud "$resource" delete "$key_name"
    fi
  done
  exit 0
fi
if [[ $action == stop ]]; then
  if ! $exists; then echo "No server named $name."; exit 0; fi
  [[ "$state" == off ]] || hcloud server shutdown "$name" --wait
  echo "Stopped Hetzner server $name."
  exit 0
fi
if ! $exists && [[ $action != deploy ]]; then
  echo "FAIL: No server named $name. Run ./byom hetzner deploy IMAGE." >&2
  exit 1
fi

require_commands ssh
key_file=${key_file:-$HOME/.ssh/isabelle-byom-$name}
[[ -f "$key_file" ]] || { echo "Supply the deployment SSH key ($key_file)." >&2; exit 1; }
remote() { hetzner_ssh "$name" "$key_file" "$@"; }
compose_dir=/opt/isabelle-byom/providers/hetzner
compose() { remote "cd $compose_dir && docker compose $1"; }

requested_host() {
  if $sslip; then
    local ip
    ip=$(hcloud server describe "$name" -o 'format={{.PublicNet.IPv4.IP}}')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Server has no public IPv4.' >&2; return 1; }
    printf '%s.sslip.io\n' "$ip"
  else
    printf '%s\n' "$hostname"
  fi
}

require_hostname() {
  if ! $sslip && [[ -z "$hostname" ]]; then
    echo 'Supply --sslip or --hostname HOST for the first installation.' >&2
    exit 1
  fi
}

provision() {
  local architecture public_key keys existing firewalls
  require_hostname
  require_commands ssh-keygen tar
  architecture=$(hcloud server-type describe "$type" -o 'format={{.Architecture}}')
  [[ "$architecture" == x86 ]] || { echo 'The shared image currently requires an x86 server type' >&2; exit 1; }
  public_key=$(ssh-keygen -y -f "$key_file")
  keys=$(hcloud ssh-key list -o noheader -o columns=name)
  if [[ $'\n'"$keys"$'\n' == *$'\n'"$key_name"$'\n'* ]]; then
    existing=$(hcloud ssh-key describe "$key_name" -o 'format={{.PublicKey}}')
    [[ "$existing" == "$public_key" ]] || { echo "SSH key $key_name already exists with different material" >&2; exit 1; }
  else hcloud ssh-key create --name "$key_name" --public-key "$public_key" --label "isabelle-byom=$name" 2>&1; fi
  firewalls=$(hcloud firewall list -o noheader -o columns=name)
  if [[ $'\n'"$firewalls"$'\n' != *$'\n'"$key_name"$'\n'* ]]; then
    hcloud firewall create --name "$key_name" --rules-file "$root/providers/hetzner/firewall.json" --label "isabelle-byom=$name" 2>&1
  fi
  hcloud server create --name "$name" --location "$location" --type "$type" --image ubuntu-24.04 \
    --start-after-create=false --ssh-key "$key_name" --firewall "$key_name" --label "isabelle-byom=$name" 2>&1
}

if ! $exists; then
  provision
  state=off
fi
if [[ $state == off ]]; then
  if [[ $action == diagnose ]]; then echo "FAIL: Server $name is off. Run ./byom hetzner start." >&2; exit 1; fi
  # Deploy uses the VM to stage files. An unsuccessful start also returns it to off.
  # shellcheck disable=SC2317
  restore_power() {
    local status=$?
    trap - EXIT
    if [[ $action == deploy || $status != 0 ]]; then
      if [[ $(hcloud server describe "$name" -o 'format={{.Status}}') != off ]]; then
        hcloud server shutdown "$name" --wait 2>&1 || status=1
      fi
    fi
    exit "$status"
  }
  trap restore_power EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  hcloud server poweron "$name" 2>&1
elif [[ $state != running ]]; then
  echo "FAIL: Server $name is $state. Retry when its power state settles." >&2
  exit 1
fi

if [[ $action != diagnose ]]; then
  ready=false
  for ((attempt=0; attempt<60; attempt++)); do
    if remote true 2>/dev/null; then ready=true; break; fi
    sleep 2
  done
  $ready || { echo 'SSH startup timed out.' >&2; exit 1; }
fi

exec 3>&1
installed=$(remote "if test -f $compose_dir/.env; then cat $compose_dir/.env; fi" 2>&3)
installed_host=$(sed -n 's/^BYOM_HOST=//p' <<< "$installed")
if $sslip || [[ -n "$hostname" ]]; then hostname=$(requested_host); else hostname=$installed_host; fi
[[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]+$ ]] || {
  echo 'Supply --sslip or --hostname HOST when deploying for the first time.' >&2
  exit 1
}

if [[ $action == deploy ]]; then
  if [[ -n "$installed_host" ]]; then
    installed_image=$(sed -n 's/^BYOM_IMAGE=//p' <<< "$installed")
    if [[ "$installed_image" == "$image" && "$installed_host" == "$hostname" ]]; then
      echo "Release staged on $name."
      exit 0
    fi
    running=$(compose 'ps --status running -q isabelle' 2>&3)
    [[ -z "$running" ]] || { echo "Stop $name before changing its release." >&2; exit 1; }
  fi
  require_commands tar
  remote 'mkdir -p /opt/isabelle-byom' 2>&1
  tar -C "$root" -cf - providers/hetzner/compose.yaml providers/hetzner/Caddyfile providers/hetzner/bootstrap.sh |
    remote 'tar -xf - -C /opt/isabelle-byom' 2>&1
  remote 'bash /opt/isabelle-byom/providers/hetzner/bootstrap.sh' 2>&1
  remote "cd $compose_dir && export BYOM_HOST='$hostname' BYOM_IMAGE='$image' && docker compose pull && docker compose create && printf '%s\\n' 'BYOM_HOST=$hostname' 'BYOM_IMAGE=$image' > .env" 2>&1
  echo "Release staged on $name."
  exit 0
fi

[[ "$installed_host" == "$hostname" ]] || { echo "Configured hostname: $installed_host." >&2; exit 1; }
url="wss://$hostname/isabelle"
if [[ $action == diagnose ]]; then
  compose "exec -T isabelle bash -s -- $url" < "$root/server/diagnose.sh" 2>&1
  exit 0
fi
compose 'start' 2>&1
attempts=12
for ((attempt=0; attempt<attempts; attempt++)); do
  if credentials=$(compose "exec -T isabelle /opt/byom/credentials.sh $url" 2>&3); then
    print_credentials "$credentials"
    exit 0
  fi
  if ((attempt+1 < attempts)); then sleep 5; fi
done
echo 'Public WSS verification failed. Run ./byom hetzner diagnose with the same access options.' >&2
exit 1
