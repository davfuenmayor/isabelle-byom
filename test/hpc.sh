#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export BYOM_TEST_DIR="$fixture" PATH="$fixture/bin:$PATH" XDG_CONFIG_HOME="$fixture/config"
unset BYOM_HPC_LOGIN BYOM_HPC_IMAGE
mkdir -p "$fixture/bin" "$XDG_CONFIG_HOME/isabelle-byom" "$fixture/shared work"
work="$fixture/shared work"
printf 'prebuilt SIF fixture\n' > "$work/byom.sif"
printf 'keep\n' > "$work/unrelated"
cat > "$XDG_CONFIG_HOME/isabelle-byom/hpc.conf" <<EOF
# Saved Slurm configuration
login=cluster-login
work-dir=$work
image=$work/byom.sif
account=research
partition=cpu
qos=normal
cpus=3
apptainer-module=tools/Apptainer
srun=true
local-port=43218
EOF

cat > "$fixture/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $1 == -* ]]; do
  case "$1" in
    -o|-F) shift 2 ;;
    -nNT) tunnel=true; shift ;;
    -S) [[ $2 == none ]]; shift 2 ;;
    -L) [[ $2 == 127.0.0.1:43218:127.0.0.1:25380 ]]; shift 2 ;;
    *) exit 1 ;;
  esac
done
if [[ ${tunnel:-false} == true ]]; then
  [[ $1 == node-17 ]]
  exec /bin/sleep 60
fi
[[ $1 == "$EXPECTED_LOGIN" && $2 == 'bash -lc '* ]]
eval "set -- ${2#bash -lc }"
exec bash -c "$1"
EOF
cat > "$fixture/bin/sbatch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *--job-name=isabelle-byom-stage* ]]; then
  [[ "$*" == *--wait* && -n "$BYOM_STAGE_IMAGE" ]]
  bash -s
  exit
fi
[[ "$BYOM_IMAGE" == "$BYOM_TEST_DIR/shared work/.byom/image-"*.sif && "$BYOM_USE_SRUN" == true ]]
[[ "$BYOM_APPTAINER_MODULE" == tools/Apptainer ]]
printf '%s\n' "$@" >> "$BYOM_TEST_DIR/submit"
cat >/dev/null
state="$BYOM_WORK_DIR/jobs/724"
mkdir -p "$state"
printf '25380\n' > "$state/port"
printf 'server "byom" = 127.0.0.1:35321 (password "test-secret")\n' > "$state/server.info"
printf '724|RUNNING|node-17|None|%s\n' "$BYOM_WORK_DIR" > "$BYOM_TEST_DIR/queue"
if [[ ${MOCK_LOST_REPLY:-0} == 1 ]]; then exit 255; fi
printf '724;test-cluster\n'
EOF
cat > "$fixture/bin/squeue" <<'EOF'
#!/usr/bin/env bash
if [[ ! -f "$BYOM_TEST_DIR/disconnected" && -f "$BYOM_TEST_DIR/queue" ]]; then
  if [[ "$*" == *'-o %Z'* ]]; then cut -d '|' -f 5- "$BYOM_TEST_DIR/queue"; else cat "$BYOM_TEST_DIR/queue"; fi
fi
EOF
cat > "$fixture/bin/apptainer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3" == 'pull --arch amd64' && $5 == docker://* ]]
printf 'mock SIF\n' > "$4"
printf '%s\n' "$5" >> "$BYOM_TEST_DIR/pull"
EOF
cat > "$fixture/bin/module" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'load tools/Apptainer' ]]
EOF
cat > "$fixture/bin/websocat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${!#} == ws://127.0.0.1:43218/isabelle ]]
read -r password
read -r command
[[ $password == test-secret && $command == 'echo "byom-ready"' ]]
touch "$BYOM_TEST_DIR/disconnected"
printf 'OK\nOK "byom-ready"\n'
EOF
cat > "$fixture/bin/scancel" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$BYOM_TEST_DIR/cancelled"
printf '%s\n' "$1" > "$BYOM_TEST_DIR/cancelling"
EOF
cat > "$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$BYOM_TEST_DIR/cancelling" ]]; then
  job=$(cat "$BYOM_TEST_DIR/cancelling")
  # The remote batch EXIT trap removes transient job state.
  dir=$(awk -F '|' -v id="$job" '$1 == id {print $5}' "$BYOM_TEST_DIR/queue")
  if [[ -d "$dir/jobs/$job" ]]; then rm -rf -- "$dir/jobs/$job"; fi
  awk -F '|' -v id="$job" '$1 != id' "$BYOM_TEST_DIR/queue" > "$BYOM_TEST_DIR/remaining"
  mv "$BYOM_TEST_DIR/remaining" "$BYOM_TEST_DIR/queue"
  rm "$BYOM_TEST_DIR/cancelling"
fi
EOF
chmod +x "$fixture"/bin/*

export EXPECTED_LOGIN=cluster-login
cp -R "$work" "$fixture/original"
if "$root/byom" hpc start > "$fixture/output" 2>&1; then exit 1; fi
mkdir "$work/.byom"
touch "$work/.byom/unrelated"
if "$root/byom" hpc destroy > "$fixture/output" 2>&1; then exit 1; fi
unlink "$work/.byom/unrelated"
rmdir "$work/.byom"
"$root/byom" hpc deploy > "$fixture/output"
"$root/byom" hpc deploy > "$fixture/output"
"$root/byom" hpc destroy
"$root/byom" hpc destroy
diff -r "$fixture/original" "$work"

printf -v digest '%064d' 1
oci="registry.example.org/isabelle-byom@sha256:$digest"
"$root/byom" hpc deploy "$oci" > "$fixture/output"
"$root/byom" hpc deploy "$oci" > "$fixture/output"
[[ $(cat "$fixture/pull") == "docker://$oci" ]]
"$root/byom" hpc destroy
diff -r "$fixture/original" "$work"

"$root/byom" hpc deploy > "$fixture/output"
cp -R "$work" "$fixture/staged"
"$root/byom" hpc > "$fixture/output"
grep -Fxq 'URL=ws://127.0.0.1:43218/isabelle' "$fixture/output"
grep -Fxq -- "--chdir=$work/.byom" "$fixture/submit"
for flag in --account=research --partition=cpu --qos=normal --cpus-per-task=3; do
  grep -Fxq -- "$flag" "$fixture/submit"
done
unlink "$fixture/disconnected"
"$root/byom" hpc stop --work-dir "$fixture/different-workspace" > "$fixture/output"
[[ ! -e "$fixture/cancelled" ]]
"$root/byom" hpc start 724 --work-dir "$fixture/different-workspace" > "$fixture/output"
grep -Fxq 'PASSWORD=test-secret' "$fixture/output"
[[ $(grep -Fc -- '--nodes=1' "$fixture/submit") == 1 ]]
unlink "$fixture/disconnected"
"$root/byom" hpc diagnose > "$fixture/output"
grep -Fq 'answered through the SSH tunnel' "$fixture/output"
if grep -q '^PASSWORD=' "$fixture/output"; then exit 1; fi
unlink "$fixture/disconnected"
if "$root/byom" hpc destroy > "$fixture/output" 2>&1; then exit 1; fi
printf '725|PENDING|n/a|Resources|%s\n' "$work/.byom" >> "$fixture/queue"
"$root/byom" hpc start 724 > "$fixture/output"
grep -Fxq 'PASSWORD=test-secret' "$fixture/output"
unlink "$fixture/disconnected"
if "$root/byom" hpc start 999 > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Slurm job 999 is no longer active' "$fixture/output"
[[ $(grep -Fc -- '--nodes=1' "$fixture/submit") == 1 ]]
if "$root/byom" hpc diagnose 725 > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'PENDING (Resources)' "$fixture/output"
if "$root/byom" hpc stop > "$fixture/output" 2>&1; then exit 1; fi
grep -Fxq '724' "$fixture/output"
grep -Fxq '725' "$fixture/output"
"$root/byom" hpc stop 724 > "$fixture/output"
grep -Fxq 'Slurm job 724 is stopped.' "$fixture/output"
[[ $(cat "$fixture/queue") == "725|PENDING|n/a|Resources|$work/.byom" ]]
"$root/byom" hpc stop 724 > "$fixture/output"
[[ $(cat "$fixture/cancelled") == 724 ]]

printf 'login=another-cluster\n' > "$fixture/other.conf"
EXPECTED_LOGIN=override-cluster "$root/byom" hpc --config "$fixture/other.conf" stop 725 --login override-cluster
EXPECTED_LOGIN=another-cluster "$root/byom" hpc --config "$fixture/other.conf" stop 725
[[ $(cat "$fixture/cancelled") == $'724\n725' ]]
[[ ! -s "$fixture/queue" ]]
diff -r "$fixture/staged" "$work"
MOCK_LOST_REPLY=1 "$root/byom" hpc start > "$fixture/output"
grep -Fxq 'Found Slurm job 724 after SSH disconnected.' "$fixture/output"
grep -Fxq 'PASSWORD=test-secret' "$fixture/output"
[[ $(grep -Fc -- '--nodes=1' "$fixture/submit") == 2 ]]
unlink "$fixture/disconnected"
"$root/byom" hpc stop 724
"$root/byom" hpc destroy
diff -r "$fixture/original" "$work"
echo 'Slurm deploy/destroy, start/stop, diagnosis and job selection passed.'
