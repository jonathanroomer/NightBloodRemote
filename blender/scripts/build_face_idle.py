"""NightBlood hero idle look-development scene:
STRONG EYES over a nearly-black field with SUBTLE background motion only.
No smoke clouds, no simulation, no mass — the background darkness drifts
almost imperceptibly; the eyes live (blinks, calm tilt, warm ivory).

The backdrop's noise layer drifts along a closed circle in texture space over
exactly LOOP_FRAMES, so frame LOOP_FRAMES+1 equals frame 1: a mathematically
perfect loop with no crossfade needed.

  blender --background --python blender/scripts/build_face_idle.py
  then render via render.py --blend blender/blends/face_idle.blend
"""

from __future__ import annotations

import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import nb_common
import nb_drift
import nb_eyes
import nb_stage

LOOP_FRAMES = 360  # 12 s at 30 fps — face spec 6.4 idle master range
DRIFT_RADIUS = 0.35  # texture-space circle radius; smaller = subtler motion


def main():
    scene = nb_common.reset_to_empty_scene()
    scene.render.fps = 30
    scene.frame_start = 1
    scene.frame_end = LOOP_FRAMES

    stage = nb_stage.build_stage(scene)
    # Presence: slightly closer camera — the eyes are the subject.
    stage["camera"].location = (0.0, -3.05, 0.76)

    rig = nb_eyes.build_eyes(scene, aperture=0.55)
    rig["rig"].location = (0.0, -0.30, 0.94)
    nb_eyes.add_blink_keys(
        rig["eyes"], 1, LOOP_FRAMES, scene.render.fps,
        base_aperture=0.55, seed=nb_common.GLOBAL_SEED,
    )

    nb_drift.animate_backdrop_drift(
        LOOP_FRAMES, radius=DRIFT_RADIUS, loops=1.0, contrast=1.0
    )

    path = nb_common.save_blend("face_idle.blend")
    print(f"[face_idle] built and saved: {path}")


main()
