#!/usr/bin/env bash
# SDK-independent native protocol checks. Development tools: websocat and jq.
set -euo pipefail
export LC_ALL=C
url=${ISABELLE_URL:?Set ISABELLE_URL to the WebSocket endpoint}
password=${ISABELLE_PASSWORD:?Set ISABELLE_PASSWORD to the native password}
for tool in websocat jq; do command -v "$tool" >/dev/null || { echo "Test tool required: $tool" >&2; exit 1; }; done
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
    command "byom_remove_project $(jq -nc --arg id "$project" '{project_id:$id}')" || true
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
read_response
[[ "$type" == OK ]]
if [[ -n ${ISABELLE_TEST_SESSION:-} ]]; then
  for ((write=0; write<50; write++)); do
    command "byom_write_file $(jq -nc --arg id "$ISABELLE_TEST_SESSION" '{session_id:$id,path:"concurrent/nested/file",text:"λ"}')"
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
project=$(jq -er .project_id <<< "$body")
project_dir=$(jq -er .dir <<< "$body")
for name in ../escape /absolute .; do
  command "byom_write_project_file $(jq -nc --arg id "$project" --arg path "$name" '{project_id:$id,path:$path,text:"no"}')"
  [[ "$type" == ERROR ]]
done
command "byom_write_project_file $(jq -nc --arg id "$project" '{project_id:$id,path:"sub/data",text:"λ"}')"
[[ "$type" == OK ]]
[[ $(jq -r .path <<< "$body") == "$project_dir/sub/data" ]]
command "byom_remove_project $(jq -nc --arg id "$project" '{project_id:$id}')"
[[ "$type" == OK ]]
command "byom_write_project_file $(jq -nc --arg id "$project" '{project_id:$id,path:"gone",text:"no"}')"
[[ "$type" == ERROR ]]
project=''
async 'session_start {"session":"HOL","options":["threads=2"]}'
session=$(jq -er .session_id <<< "$body")
for name in ../escape /absolute .; do
  command "byom_write_file $(jq -nc --arg id "$session" --arg path "$name" '{session_id:$id,path:$path,text:"no"}')"
  [[ "$type" == ERROR ]]
done
command "byom_write_file $(jq -nc --arg id "$session" '{session_id:$id,path:"bad\u0000path",text:"no"}')"
[[ "$type" == ERROR ]]
# A parent that is a file must yield ERROR without breaking the connection.
command "byom_write_file $(jq -nc --arg id "$session" '{session_id:$id,path:"blocked",text:"file"}')"
[[ "$type" == OK ]]
command "byom_write_file $(jq -nc --arg id "$session" '{session_id:$id,path:"blocked/child",text:"no"}')"
[[ "$type" == ERROR ]]
command "byom_write_file $(jq -nc --arg id "$session" '{session_id:$id,path:"Example.thy",text:"theory Example imports Main begin\nlemma \"x = x\" by simp\nend\n"}')"
[[ "$type" == OK ]]
path=$(jq -er .path <<< "$body")
async "use_theories $(jq -nc --arg id "$session" --arg dir "${path%/*}" '{session_id:$id,master_dir:$dir,theories:["Example"]}')"
jq -e '.ok == true' <<< "$body" >/dev/null
ISABELLE_TEST_SESSION="$session" bash "$0" > "$tmp/writer.log" 2>&1 &
writer=$!
async "session_stop $(jq -nc --arg id "$session" '{session_id:$id}')"
wait "$writer"
command "byom_write_file $(jq -nc --arg id "$session" '{session_id:$id,path:"after-stop",text:"no"}')"
[[ "$type" == ERROR ]]
session=''
echo 'Native WebSocket framing, authentication, HOL, session files and project lifecycle passed.'
