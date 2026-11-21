#!/usr/bin/env bash
set -euo pipefail
state="$BYOM_WORK_DIR/jobs/$SLURM_JOB_ID"
mkdir -p "$BYOM_WORK_DIR/jobs"
mkdir -m 700 "$state"
scratch=''
child=''
cleanup() {
  [[ -z "$scratch" ]] || rm -rf -- "$scratch"
  rm -rf -- "$state"
}
stop() {
  if [[ -n "$child" ]]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" || true
  fi
  exit 143
}
trap cleanup EXIT
trap stop INT TERM

scratch=$(mktemp -d "${TMPDIR:-/tmp}/byom-hpc.XXXXXXXX")
port=$(shuf -i 20000-60000 -n 1)
printf '%s\n' "$port" > "$state/port"

export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$scratch}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$BYOM_WORK_DIR/apptainer-cache}"
cpus="${SLURM_CPUS_PER_TASK:-1}"
runner=(apptainer)
if [[ ${BYOM_USE_SRUN:-false} == true ]]; then
  runner=(srun --ntasks=1 "--cpus-per-task=$cpus" "${runner[@]}")
fi
if [[ -n ${BYOM_APPTAINER_MODULE:-} ]]; then
  # The login shell supplies the module function and expands its arguments.
  # shellcheck disable=SC2016
  runner=(bash --login -c 'module load "$1" || exit; shift; exec "$@"' byom
    "$BYOM_APPTAINER_MODULE" "${runner[@]}")
fi
echo "Starting Isabelle on $(hostname) (Slurm job $SLURM_JOB_ID)"
"${runner[@]}" exec --cleanenv --no-eval --contain --no-mount home,cwd,hostfs,/home --pwd / \
  --bind "$scratch:/tmp,$state:/run/byom" \
  --env "PORT=$port,ISABELLE_SERVER_PORT=0,BYOM_BIND_ADDRESS=127.0.0.1,BYOM_INFO=/run/byom/server.info,BYOM_THREADS=$cpus,LANG=C.UTF-8" \
  --env "BYOM_JAVA_OPTIONS=-Djava.awt.headless=true -Xms128m -Xmx1g -Xss16m -XX:ActiveProcessorCount=$cpus" \
  "$BYOM_IMAGE" /usr/bin/tini -s -- /opt/byom/start.sh &
child=$!
wait "$child"
