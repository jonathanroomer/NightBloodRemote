#!/bin/sh
# Rebuild, render, encode and seam-check every non-idle face-state loop.
set -eu

BLENDER_BIN=${BLENDER_BIN:-blender}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
STATES="offline starting listening transcribing routing thinking working speaking waiting_approval completed error event_gap degraded"

cd "$PROJECT_ROOT"
mkdir -p blender/blends blender/renders/state_loops

for state in $STATES; do
  NB_STATE=$state NB_LOOP_FRAMES=240 "$BLENDER_BIN" \
    --background --python blender/scripts/build_face_states.py

  "$BLENDER_BIN" --background --python blender/scripts/render.py -- \
    --profile preview \
    --blend "blender/blends/face_state_${state}.blend" \
    --frames 1-240 \
    --out "blender/renders/state_loops/${state}_" \
    --format PNG

  python3 blender/scripts/make_clip.py \
    --seq "blender/renders/state_loops/${state}_" \
    --start 1 \
    --count 240 \
    --out "blender/renders/state_loops/${state}_8s.mp4"
done

printf '%s\n' "Rendered all face-state loops. Run the seam-check command in docs/FACE_CREATION.md before accepting them."
