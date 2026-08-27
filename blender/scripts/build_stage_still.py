"""Phase 0 foundation scene: empty stage plus eye rig.

Run via render.py --build, e.g.:

  blender --background \
      --python blender/scripts/render.py -- \
      --profile production --build blender/scripts/build_stage_still.py \
      --frames 1 --out blender/renders/phase0/stage_production_ --format PNG
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import nb_common
import nb_eyes
import nb_stage

scene = nb_common.reset_to_empty_scene()
stage = nb_stage.build_stage(scene)
eye_rig = nb_eyes.build_eyes(scene, aperture=0.55)

nb_common.save_blend("stage_foundation.blend")
print("[build_stage_still] stage + eye rig built and saved")
