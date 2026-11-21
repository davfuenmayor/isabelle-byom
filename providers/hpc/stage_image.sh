#!/bin/bash -l
set -euo pipefail
source_image=${BYOM_STAGE_IMAGE:?Missing staging image}
module_name=${BYOM_APPTAINER_MODULE:-}
scratch=$(mktemp -d .stage.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
if [[ "$source_image" == /* ]]; then
  test -s "$source_image"
  cp -- "$source_image" "$scratch/image.sif"
else
  if [[ -n "$module_name" ]]; then module load "$module_name"; fi
  export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$PWD/apptainer-cache}"
  apptainer pull --arch amd64 "$scratch/image.sif" "$source_image"
fi
checksum=$(printf '%s' "$source_image" | sha256sum)
image="image-${checksum%% *}.sif"
mv -f -- "$scratch/image.sif" "$image"
printf '%s\n' "$source_image" "$image" > "$scratch/release"
mv -f -- "$scratch/release" release
