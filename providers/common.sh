#!/usr/bin/env bash
# Shared deployer input and output. Provider resources and lifecycle stay in their scripts.

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || { echo "Required command: $command_name" >&2; exit 1; }
  done
}

read_token() {
  local token
  if [[ -n "$1" ]]; then token=$(cat < "$1")
  elif [[ -n "$2" ]]; then token=$2
  else read -r -s -p "$3: " token; echo >&2; fi
  [[ -n "$token" ]] || { echo 'Empty provider token' >&2; return 1; }
  printf '%s' "$token"
}

print_credentials() {
  printf '\n=== Isabelle server credentials ===\n%s\n===================================\n' "$1"
}

is_pinned_image() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[a-f0-9]{64}$ ]]
}
