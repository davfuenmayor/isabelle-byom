#!/usr/bin/env bash

hetzner_ssh() {
  local name=$1 key_file=$2
  shift 2
  hcloud server ssh "$name" -i "$key_file" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$key_file.known_hosts" "$@"
}
