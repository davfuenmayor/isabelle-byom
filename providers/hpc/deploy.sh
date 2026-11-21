#!/usr/bin/env bash
set -euo pipefail
dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() {
  cat <<'EOF'
Usage: ./byom hpc [--config FILE] deploy IMAGE [OPTIONS]
       ./byom hpc [--config FILE] [start|stop|diagnose] [JOB_ID] [OPTIONS]
       ./byom hpc [--config FILE] destroy [OPTIONS]

Save login=HOST and image=IMAGE in ${XDG_CONFIG_HOME:-$HOME/.config}/isabelle-byom/hpc.conf.
Use --config FILE before the command to select a different file.
If you omit JOB_ID, BYOM selects the only active job in the workspace.
Start submits a new job if there is no active one.

Options:
  --login HOST            SSH alias or [user@]hostname for the Slurm login node
  --image IMAGE           Deploy input: absolute shared SIF or pinned OCI reference
  --ssh-config FILE       Use a specific OpenSSH configuration
  --work-dir DIR          Existing shared workspace (default: $WORK or $HOME)
  --partition NAME        Slurm partition (defaults to the site's selection)
  --account NAME          Slurm account to charge
  --qos NAME              Slurm quality of service
  --cpus N                CPUs for start (default: 4)
  --mem SIZE              Memory for start (defaults to the site's allocation)
  --walltime TIME         Slurm time limit (default: 01:00:00)
  --apptainer-module NAME  Load an environment module on the compute node
  --srun                  Launch the container as a Slurm job step
  --wait SECONDS          Queue, startup, or stop wait (default: 600)
  --local-port PORT       Loopback tunnel port (default: chosen automatically)
EOF
  exit "${1:-0}"
}
settings="${XDG_CONFIG_HOME:-$HOME/.config}/isabelle-byom/hpc.conf"
if [[ ${1:-} == --config ]]; then
  (($# >= 2)) || usage 1 >&2
  settings=$2
  [[ -f "$settings" ]] || { echo "Cannot read BYOM configuration at $settings." >&2; exit 1; }
  shift 2
fi
action=start
case "${1:-}" in
  deploy|start|stop|diagnose|destroy) action=$1; shift ;;
  -h|--help) usage ;;
  ''|-*) ;;
  *) usage 1 >&2 ;;
esac

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common.sh
source "$dir/../common.sh"
job='' config='' work='' partition='' account='' qos='' cpus=4 mem='' walltime=01:00:00 delay=600
apptainer_module='' use_srun=false
login='' image='' requested_image=''
local_port=$((20000 + RANDOM))
if [[ -n ${1:-} && ${1:-} != -* ]]; then
  case "$action" in
    deploy) requested_image=$1 ;;
    start|stop|diagnose) job=$1; [[ "$job" =~ ^[1-9][0-9]*$ ]] || usage 1 >&2 ;;
    *) usage 1 >&2 ;;
  esac
  shift
fi

set_option() {
  case "$1" in
    login) login=$2 ;;
    image) image=$2 ;;
    ssh-config) config=$2 ;;
    work-dir) work=$2 ;;
    partition) partition=$2 ;;
    account) account=$2 ;;
    qos) qos=$2 ;;
    cpus) cpus=$2 ;;
    mem) mem=$2 ;;
    walltime) walltime=$2 ;;
    apptainer-module) apptainer_module=$2 ;;
    srun) use_srun=$2 ;;
    wait) delay=$2 ;;
    local-port) local_port=$2 ;;
    *) return 1 ;;
  esac
}

if [[ -f "$settings" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      *=*) if set_option "${line%%=*}" "${line#*=}"; then continue; fi ;;
    esac
    echo "Invalid BYOM setting in $settings ($line)." >&2
    exit 1
  done < "$settings"
fi
login=${BYOM_HPC_LOGIN:-$login}
image=${requested_image:-${BYOM_HPC_IMAGE:-$image}}

while (($#)); do
  case "$1" in
    -h|--help) usage ;;
    --srun)
      [[ $action == start ]] || usage 1 >&2
      use_srun=true
      shift
      continue ;;
  esac
  (($# >= 2)) || usage 1 >&2
  case "$1" in
    --login|--ssh-config|--work-dir|--wait|--local-port) ;;
    --image) [[ $action == deploy ]] || usage 1 >&2 ;;
    --partition|--account|--qos|--cpus|--mem|--walltime|--apptainer-module)
      [[ $action == deploy || $action == start ]] || usage 1 >&2 ;;
    *) usage 1 >&2 ;;
  esac
  set_option "${1#--}" "$2"
  shift 2
done
[[ "$delay" =~ ^[1-9][0-9]{0,5}$ && "$local_port" =~ ^[1-9][0-9]{0,4}$ ]] || usage 1 >&2
((local_port <= 65535)) || usage 1 >&2
[[ "$use_srun" == true || "$use_srun" == false ]] || { echo 'Set srun to true or false in the BYOM configuration.' >&2; exit 1; }
[[ -n "$login" ]] || { echo "Set login=HOST in $settings or pass --login HOST." >&2; exit 1; }
[[ "$login" != -* ]] || usage 1 >&2

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
if [[ -n "$config" ]]; then ssh_args+=(-F "$config"); fi
remote() {
  local command
  printf -v command 'bash -lc %q' "$1"
  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$login" "$command"
}
queue_status() {
  local query="squeue -h --me -n isabelle-byom -o '%i|%T|%B|%r|%Z'"
  local status=0
  remote "$query" || status=$?
  if ((status == 255)); then
    sleep 5
    remote "$query"
  else
    return "$status"
  fi
}

job_status() {
  queue_status | awk -F '|' -v id="$job" '$1 == id'
}

workspace() {
  # shellcheck disable=SC2016
  if [[ -z "$work" ]]; then work=$(remote 'printf "%s\n" "${WORK:-$HOME}"'); fi
  [[ "$work" == /* && "$work" != *[,:$'\n']* ]] ||
    { echo 'The Slurm workspace must be an absolute shared path without commas, colons, or newlines.' >&2; exit 1; }
  work=${work%/}/.byom
}

scheduler_options() {
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || usage 1 >&2
  slurm_args=(--parsable --nodes=1 --ntasks=1 "--cpus-per-task=$cpus" "--time=$walltime" "--chdir=$work")
  [[ -z "$partition" ]] || slurm_args+=("--partition=$partition")
  [[ -z "$account" ]] || slurm_args+=("--account=$account")
  [[ -z "$qos" ]] || slurm_args+=("--qos=$qos")
  [[ -z "$mem" ]] || slurm_args+=("--mem=$mem")
}

staged_image() {
  local source path
  printf -v read_release 'if test -f %q && test -f %q; then cat %q; fi' \
    "$work/.owned" "$work/release" "$work/release"
  staged=$(remote "$read_release")
  {
    IFS= read -r source
    IFS= read -r path || true
  } <<< "$staged"
  staged=$source
  staged_path=''
  if [[ "$path" =~ ^image-[a-f0-9]{64}\.sif$ ]]; then
    staged_path="$work/$path"
  fi
}

require_commands ssh
if [[ $action == deploy || $action == destroy ]]; then
  workspace
  printf -v check_owner 'if test -L %q; then echo foreign; elif test -f %q; then echo owned; elif test -e %q; then echo foreign; fi' \
    "$work" "$work/.owned" "$work"
  ownership=$(remote "$check_owner")
  [[ "$ownership" != foreign ]] || { echo "Refusing to manage $work without a BYOM ownership marker." >&2; exit 1; }
  if [[ $action == destroy && -z "$ownership" ]]; then
    echo "No deployment in $work."
    exit 0
  fi
  if [[ $action == deploy ]]; then
    if ! remote "test -d $(printf '%q' "${work%/.byom}")"; then
      echo "Create the shared workspace ${work%/.byom} first." >&2
      exit 1
    fi
    staged_image
    if [[ "$image" != /*.sif || "$image" == *$'\n'* ]]; then
      image=${image#docker://}
      is_pinned_image "$image" ||
        { echo 'Supply a pinned OCI image or an absolute shared SIF path.' >&2; exit 1; }
      image="docker://$image"
    fi
    if [[ "$staged" == "$image" && -n "$staged_path" ]] && remote "test -s $(printf '%q' "$staged_path")"; then
      echo "Release staged in $work."
      exit 0
    fi
  fi
  jobs=$(remote "squeue -h --me -n isabelle-byom,isabelle-byom-stage -o '%Z'")
  if [[ $'\n'"$jobs"$'\n' == *$'\n'"$work"$'\n'* ]]; then
    echo "Wait for staging to finish or stop the Isabelle job in $work first." >&2
    exit 1
  fi
  if [[ $action == destroy ]]; then
    printf -v remove 'rm -rf -- %q' "$work"
    remote "$remove"
    echo "Removed the deployment in $work."
    exit 0
  fi
  if [[ -z "$ownership" ]]; then
    printf -v claim 'mkdir -- %q && touch -- %q' "$work" "$work/.owned"
    remote "$claim"
  fi
  printf -v prepare 'mkdir -p -- %q %q && cd -- %q' "$work/logs" "$work/jobs" "$work"
  printf -v stage_env 'BYOM_STAGE_IMAGE=%q BYOM_APPTAINER_MODULE=%q' "$image" "$apptainer_module"
  if [[ "$image" == /* ]]; then
    printf -v stage '%s && %s bash -s' "$prepare" "$stage_env"
  else
    scheduler_options
    slurm_args+=(--wait --export=ALL --job-name=isabelle-byom-stage "--output=$work/stage.log")
    printf -v options '%q ' "${slurm_args[@]}"
    printf -v stage '%s && %s sbatch %s' "$prepare" "$stage_env" "$options"
  fi
  if ! remote "$stage" < "$dir/stage_image.sh"; then
    echo "Staging failed. See $work/stage.log for the batch output." >&2
    exit 1
  fi
  echo "Release staged in $work."
  exit 0
fi

if [[ -z "$job" ]]; then
  workspace
  ids=$(queue_status | while IFS='|' read -r id _ _ _ job_dir; do
    if [[ "$id" =~ ^[1-9][0-9]*$ && "$job_dir" == "$work" ]]; then printf '%s\n' "$id"; fi
  done)
  if [[ "$ids" == *$'\n'* ]]; then
    echo "Choose a job ID for ./byom hpc $action. Active jobs in $work:" >&2
    printf '%s\n' "$ids" >&2
    exit 1
  fi
  job=$ids
fi
if [[ -z "$job" && $action != start ]]; then
  echo "No active Isabelle BYOM jobs in $work."
  if [[ $action == stop ]]; then exit 0; fi
  exit 1
fi
if [[ $action == stop ]]; then
  status=$(job_status)
  IFS='|' read -r _ _ _ _ job_dir <<< "$status"
  if [[ -n "$status" && "$status" != "$job|COMPLETING|"* ]] && ! remote "scancel $job"; then
    status=$(job_status)
    [[ -z "$status" ]] || exit 1
  fi
  deadline=$((SECONDS + delay))
  while [[ -n "$status" ]]; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for Slurm job $job to exit." >&2
      exit 1
    fi
    sleep 2
    status=$(job_status)
  done
  if [[ "$job_dir" == /*/.byom ]]; then
    printf -v clear_log 'rm -f -- %q' "$job_dir/logs/$job.log"
    remote "$clear_log"
  fi
  echo "Slurm job $job is stopped."
  exit 0
fi
require_commands websocat
if [[ -z "$job" ]]; then
  staged_image
  image=$staged_path
  if [[ -z "$image" ]] || ! remote "test -s $(printf '%q' "$image")"; then
    echo "Deploy an image in $work first." >&2
    exit 1
  fi
else
  status=$(job_status)
  [[ -n "$status" ]] || { echo "Slurm job $job is no longer active." >&2; exit 1; }
  IFS='|' read -r _ _ _ _ work <<< "$status"
fi
[[ "$work" == /* && "$work" != *[,:$'\n']* ]] ||
  { echo 'The Slurm workspace must be an absolute shared path without commas, colons, or newlines.' >&2; exit 1; }
if [[ -z "$job" ]]; then
  echo "Submitting Isabelle through $login ($cpus CPUs, $walltime)"
  scheduler_options
  slurm_args+=(--job-name=isabelle-byom "--output=$work/logs/%j.log" --export=ALL)
  printf -v options '%q ' "${slurm_args[@]}"
  printf -v submit 'mkdir -p -- %q && BYOM_WORK_DIR=%q BYOM_IMAGE=%q BYOM_APPTAINER_MODULE=%q BYOM_USE_SRUN=%q sbatch %s' \
    "$work/logs" "$work" "$image" "$apptainer_module" "$use_srun" "$options"
  if result=$(remote "$submit" < "$dir/start_isabelle.sh"); then
    job=${result%%;*}
    [[ "$job" =~ ^[1-9][0-9]*$ ]] || { echo "Unexpected Slurm submission response: $result" >&2; exit 1; }
  else
    status=$?
    ((status == 255)) || exit "$status"
    # SSH can disconnect after sbatch accepts the job. Inspect the queue before retrying.
    job=$(queue_status | while IFS='|' read -r id _ _ _ job_dir; do
      if [[ "$job_dir" == "$work" ]]; then printf '%s\n' "$id"; fi
    done)
    [[ "$job" =~ ^[1-9][0-9]*$ ]] || {
      echo 'SSH disconnected during submission. Run start again to check for an existing job.' >&2
      exit 1
    }
    echo "Found Slurm job $job after SSH disconnected."
  fi
fi
echo "Slurm job $job. Log on $login at $work/logs/$job.log"

reconnect_hint() {
  local args=(start "$job" --login "$login")
  [[ -z "$config" ]] || args+=(--ssh-config "$config")
  printf 'Reconnect with ./byom hpc' >&2
  [[ ! -f "$settings" ]] || printf ' --config %q' "$settings" >&2
  printf ' %q' "${args[@]}" >&2
  printf '\n' >&2
}

tmp=$(mktemp -d)
tunnel=''
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "$tunnel" ]]; then
    kill "$tunnel" 2>/dev/null || true
    wait "$tunnel" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
deadline=$((SECONDS + delay))
if [[ $action == diagnose ]]; then deadline=$((SECONDS + 15)); fi
state="$work/jobs/$job"
printf -v read_state 'cat -- %q %q' "$state/port" "$state/server.info"
previous=''
port=''
while ((SECONDS < deadline)); do
  status=$(job_status)
  [[ -n "$status" ]] || { echo "Slurm job $job is no longer active. Check its log." >&2; exit 1; }
  IFS='|' read -r _ phase node reason _ <<< "$status"
  if [[ "$status" != "$previous" ]]; then
    if [[ "$phase" == PENDING ]]; then
      echo "Slurm job $job is $phase ($reason)"
    else
      echo "Slurm job $job is $phase"
    fi
    previous=$status
  fi
  if [[ "$phase" == RUNNING ]] && remote "$read_state" > "$tmp/ready" 2>/dev/null; then
    IFS= read -r port < "$tmp/ready"
    if [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) &&
       grep -Eq '^server "byom" = 127\.0\.0\.1:[0-9]+ \(password "[^"]+"\)$' "$tmp/ready"; then break; fi
    port=''
  fi
  if [[ $action == diagnose ]]; then
    echo "Job $job has no ready Isabelle endpoint. See the Slurm status and log above." >&2
    exit 1
  fi
  sleep 5
done
if [[ -z "$port" ]]; then
  echo "Timed out waiting for job $job. Its allocation may still start." >&2
  reconnect_hint
  exit 1
fi
[[ "$node" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] ||
  { echo "Slurm did not return a usable SSH host for job $job ($node)." >&2; exit 1; }

echo "Opening an SSH tunnel to $node"
# BYOM owns this tunnel's process and lifetime even if login SSH is multiplexed.
ssh "${ssh_args[@]}" -nNT -S none -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:$local_port:127.0.0.1:$port" "$node" &
tunnel=$!
url="ws://127.0.0.1:$local_port/isabelle"
while ((SECONDS < deadline)) && kill -0 "$tunnel" 2>/dev/null; do
  if credentials=$(BYOM_INFO="$tmp/ready" "$dir/../../server/credentials.sh" "$url" 2>/dev/null); then
    if [[ $action == diagnose ]]; then
      echo "Isabelle in job $job answered through the SSH tunnel."
      exit 0
    fi
    echo "Keep this command running while using the local tunnel."
    print_credentials "$credentials"
    while kill -0 "$tunnel" 2>/dev/null; do
      sleep 30
      status=$(job_status)
      [[ -n "$status" ]] || { echo "Slurm job $job has ended."; exit 0; }
    done
    wait "$tunnel"
    exit 0
  fi
  if kill -0 "$tunnel" 2>/dev/null; then sleep 5; fi
done
echo "Could not authenticate through the SSH tunnel for job $job. Check the SSH output and Slurm log." >&2
reconnect_hint
exit 1
