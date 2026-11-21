#!/usr/bin/env bash
# SDK-independent native protocol checks. Development tools: websocat, jq and base64.
set -euo pipefail
export LC_ALL=C
url=${ISABELLE_URL:?Set ISABELLE_URL to the WebSocket endpoint}
password=${ISABELLE_PASSWORD:?Set ISABELLE_PASSWORD to the native password}
for tool in websocat jq base64; do command -v "$tool" >/dev/null || { echo "Test tool required: $tool" >&2; exit 1; }; done
tmp=$(mktemp -d)
session='' project='' ws_pid='' writer=''
write_message() {
  local message=$1
  if ((${#message} > 100)) || [[ "$message" == *$'\n'* || "$message" =~ ^[0-9]+$ ]]; then
    printf '%s\n%s\n' "$((${#message}+1))" "$message" >&3
  else printf '%s\n' "$message" >&3; fi
}
read_response() {
  local line
  IFS= read -r -t 120 line <&4
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    ((line > 0 && line <= 16777216))
    IFS= read -r -N "$line" -t 120 line <&4
    line=${line%$'\n'}
  fi
  type=${line%% *}
  body=null
  [[ "$line" != *' '* ]] || body=${line#* }
}
command() {
  write_message "$1"
  while read_response; do [[ "$type" != NOTE ]] && return; done
  return 1
}
upload_yxml() {
  local request
  printf -v request '%s \005\006file\006%s=%s\006path=%s\005%s\005\006\005' \
    "$1" "$2" "$3" "$4" "$5"
  command "$request"
}
upload() {
  local path text
  path=$(printf '%s' "$4" | base64 | tr -d '\n')
  text=$(printf '%s' "$5" | base64 | tr -d '\n')
  upload_yxml "$1" "$2" "$3" "$path" "$text"
}
project_file() { upload byom_write_project_file project_id "$project" "$@"; }
session_file() { upload byom_write_file session_id "$session" "$@"; }
remove_project() { command $'byom_remove_project \005\006project\006project_id='"$project"$'\005\005\006\005'; }
result_field() {
  local prefix=$'\005\006byom\006' suffix=$'\005\005\006\005'
  local attrs field fields
  [[ "$body" == "$prefix"*"$suffix" ]] || return 1
  attrs=${body#"$prefix"}
  IFS=$'\006' read -r -a fields <<< "${attrs%"$suffix"}"
  for field in "${fields[@]}"; do
    if [[ "$field" == "$1="* ]]; then
      printf '%s\n' "${field#*=}" | jq -Rr @base64d
      return
    fi
  done
  return 1
}
async() {
  command "$1"
  [[ "$type" == OK ]]
  local task
  task=$(jq -er .task <<< "$body")
  while read_response; do
    if [[ "$type" == FINISHED || "$type" == FAILED ]]; then
      [[ $(jq -r .task <<< "$body") == "$task" ]]
      [[ "$type" == FINISHED ]]
      return
    fi
  done
  return 1
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  # Cleanup also runs after a failed assertion, before closing the connection.
  if [[ -n "$session" ]]; then
    async "session_stop $(jq -nc --arg id "$session" '{session_id:$id}')" || true
  fi
  if [[ -n "$project" ]]; then
    remove_project || true
  fi
  [[ -z "$writer" ]] || kill "$writer" 2>/dev/null || true
  [[ -z "$ws_pid" ]] || kill "$ws_pid" 2>/dev/null || true
  wait || true
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkfifo "$tmp/in" "$tmp/out"
websocat -b -n "$url" < "$tmp/in" > "$tmp/out" 2> "$tmp/ws.log" &
ws_pid=$!
exec 3> "$tmp/in" 4< "$tmp/out"
write_message "$password"
if [[ ${ISABELLE_TEST_REJECT_AUTH:-0} == 1 ]]; then
  if IFS= read -r -t 10 <&4; then
    echo 'The server replied to an invalid password.' >&2
    exit 1
  fi
  echo 'The server withheld its authentication reply.'
  exit 0
fi
read_response
[[ "$type" == OK ]]
if [[ -n ${ISABELLE_TEST_SESSION:-} ]]; then
  for ((write=0; write<50; write++)); do
    upload byom_write_file session_id "$ISABELLE_TEST_SESSION" concurrent/nested/file λ
    [[ "$type" == OK || "$type" == ERROR ]]
    sleep 0.05
  done
  exit 0
fi
command help
[[ "$type" == OK ]]
jq -e 'index("byom_write_file") != null' <<< "$body" >/dev/null
# Native length framing, including multibyte UTF-8, independently of WS frames.
payload=$(jq -nc '{text: ("λ🙂\n" * 10000)}')
command "echo $payload"
[[ "$type" == OK && $(jq -c . <<< "$body") == "$payload" ]]
command byom_create_project
[[ "$type" == OK ]]
project=$(result_field project_id)
project_dir=$(result_field dir)
for name in ../escape /absolute .; do
  project_file "$name" no
  [[ "$type" == ERROR ]]
done
project_file 'sub/data' $'λ\005\006\n'
[[ "$type" == OK ]]
[[ $(result_field path) == "$project_dir/sub/data" ]]
project_file empty ''
[[ "$type" == OK ]]
upload_yxml byom_write_project_file project_id "$project" YmFk '@@@'
[[ "$type" == ERROR ]]
upload_yxml byom_write_project_file project_id "$project" YmFk '/w=='
[[ "$type" == ERROR ]]
remove_project
[[ "$type" == OK ]]
[[ $(result_field removed) == "$project" ]]
project_file gone no
[[ "$type" == ERROR ]]
project=''
async 'session_start {"session":"HOL","options":["threads=2"]}'
session=$(jq -er .session_id <<< "$body")
for name in ../escape /absolute .; do
  session_file "$name" no
  [[ "$type" == ERROR ]]
done
upload_yxml byom_write_file session_id "$session" YmFkAHBhdGg= bm8=
[[ "$type" == ERROR ]]
# A parent that is a file must yield ERROR without breaking the connection.
session_file blocked file
[[ "$type" == OK ]]
session_file blocked/child no
[[ "$type" == ERROR ]]
session_file Example.thy $'theory Example imports Main begin\nlemma "x = x" by simp\nend\n'
[[ "$type" == OK ]]
path=$(result_field path)
async "use_theories $(jq -nc --arg id "$session" --arg dir "${path%/*}" '{session_id:$id,master_dir:$dir,theories:["Example"]}')"
jq -e '.ok == true' <<< "$body" >/dev/null
ISABELLE_TEST_SESSION="$session" bash "$0" > "$tmp/writer.log" 2>&1 &
writer=$!
async "session_stop $(jq -nc --arg id "$session" '{session_id:$id}')"
wait "$writer"
session_file after-stop no
[[ "$type" == ERROR ]]
session=''
echo 'Native WebSocket framing, authentication, HOL, session files and project lifecycle passed.'
