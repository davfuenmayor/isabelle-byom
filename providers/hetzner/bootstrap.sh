#!/usr/bin/env bash
# Runs on the newly provisioned Ubuntu server, not the deployer's computer.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait >/dev/null
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker.io docker-compose-v2
fi
systemctl enable --now docker
# Concurrent HOL sessions plus a heap build can exceed physical RAM briefly.
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then swapon /swapfile; fi
if ! grep -q '^/swapfile ' /etc/fstab; then echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi
