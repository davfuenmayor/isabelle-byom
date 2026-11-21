#!/usr/bin/env bash

fly_exec() {
  local app=$1 machine=$2 seconds=$3 command=$4 result
  result=$(fly machine exec "$machine" "$command" --app "$app" --timeout "$seconds" --json) || return
  jq -jr '.stderr // empty' <<< "$result" >&2
  jq -jr '.stdout // empty' <<< "$result"
  # flyctl returns success even when the command inside the Machine failed.
  jq -e 'type == "object" and (.exit_code // 0) == 0' <<< "$result" >/dev/null
}
