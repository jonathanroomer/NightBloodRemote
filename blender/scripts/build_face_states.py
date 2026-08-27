"""Per-state face scenes in the minimal hero language (see lib/nb_states.py).

  NB_STATE=thinking blender --background --python blender/scripts/build_face_states.py
  then render via render.py --blend blender/blends/face_state_<state>.blend

Builds the idle architecture (stage + eyes + closed-circle backdrop drift)
and applies the state's parameters: aperture, gaze, eye gain, blink policy,
drift character, backdrop tint/gain, and for `speaking` the embedded ivory
waveform below the eyes (driven at runtime by authorised amplitude only; the
baked snapshot here is explicitly a look target, not a mouth simulation).
"""

from __future__ import annotations

import math
import os
import random
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import nb_common
import nb_drift
import nb_eyes
import nb_stage
import nb_states

STATE = os.environ.get("NB_STATE", "idle")
if STATE not in nb_common.STATE_NAMES:
    raise SystemExit(f"unknown state: {STATE}")

# Loop length in frames; drift circles and blink holds close exactly here.
LOOP_FRAMES = int(os.environ.get("NB_LOOP_FRAMES", "360"))
PARAMS = nb_states.STATE_PARAMS[STATE]


def animate_backdrop_drift(radius: float, loops: float, contrast: float):
    """State tint on the backdrop, then the shared living-drift animation
    (translation + evolution churn + breathing) from nb_drift."""
    mat = bpy.data.materials["NB_BackdropMat"]
    ramp = next(n for n in mat.node_tree.nodes if n.type == "VALTORGB")
    ramp.color_ramp.elements[1].color = (*nb_states.backdrop_colour(PARAMS), 1.0)
    nb_drift.animate_backdrop_drift(LOOP_FRAMES, radius, loops, contrast)


def scale_eye_brightness(gain: float):
    """Post-adjust the built NB_EyeCore/NB_EyeHalo materials (lib untouched)."""
    core = bpy.data.materials["NB_EyeCore"]
    for node in core.node_tree.nodes:
        if node.type == "MAP_RANGE":
            node.inputs["To Min"].default_value *= gain
            node.inputs["To Max"].default_value *= gain
    halo = bpy.data.materials["NB_EyeHalo"]
    for node in halo.node_tree.nodes:
        if node.type == "MATH" and node.operation == "MULTIPLY":
            node.inputs[1].default_value *= gain
            break


def apply_blinks(rig, fps: int):
    policy = PARAMS["blink"]
    if policy == "none" or policy == "suppressed":
        nb_eyes.set_aperture(rig["eyes"], PARAMS["aperture"])
        return
    interval = {"natural": (4.0, 9.0), "sparse": (7.0, 13.0), "slow": (6.0, 10.0)}[policy]
    nb_eyes.add_blink_keys(
        rig["eyes"], 1, LOOP_FRAMES, fps,
        base_aperture=PARAMS["aperture"],
        seed=nb_common.GLOBAL_SEED + nb_common.STATE_NAMES.index(STATE),
        interval_s=interval,
    )


def build_waveform(amplitude: float):
    """Embedded ivory waveform below the eyes (speaking look target). A thin
    emissive ribbon whose profile is a seeded audio-like envelope."""
    if amplitude <= 0.0:
        return None
    rng = random.Random(nb_common.GLOBAL_SEED + 7)
    n = 220
    width = 0.98
    verts = []
    heights = []
    h = 0.0
    for i in range(n):
        target = (rng.random() ** 2.2) * (0.5 + 0.5 * math.sin(i * 0.23 + rng.random()))
        h = h * 0.72 + target * 0.28
        heights.append(h)
    peak = max(heights) or 1.0
    for i in range(n):
        x = -width / 2 + width * i / (n - 1)
        z = 0.028 * amplitude * heights[i] / peak
        verts.append((x, 0.0, z))
        verts.append((x, 0.0, -z * 0.85))
    faces = []
    for i in range(n - 1):
        a, b, c, d = 2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2
        faces.append((a, b, c, d))
    mesh = bpy.data.meshes.new("NB_Waveform")
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new("NB_Waveform", mesh)
    obj.location = (0.0, -0.30, 0.52)
    nb_common.link_object(obj)

    mat = nb_common.new_node_material("NB_WaveformMat")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (1.0, 0.90, 0.68, 1.0)
    emit.inputs["Strength"].default_value = 5.0
    links.new(emit.outputs["Emission"], out.inputs["Surface"])
    obj.data.materials.append(mat)
    obj.visible_shadow = False
    return obj


def main():
    scene = nb_common.reset_to_empty_scene()
    scene.render.fps = 30
    scene.frame_start = 1
    scene.frame_end = LOOP_FRAMES

    stage = nb_stage.build_stage(scene)
    stage["camera"].location = (0.0, -3.05, 0.76)

    rig = nb_eyes.build_eyes(scene, aperture=PARAMS["aperture"])
    rig["rig"].location = (0.0, -0.30, 0.94)
    nb_eyes.set_gaze(rig["rig"], *PARAMS["gaze"])
    scale_eye_brightness(PARAMS["eye_gain"])
    apply_blinks(rig, scene.render.fps)

    animate_backdrop_drift(
        PARAMS["drift_radius"], PARAMS["drift_loops"], PARAMS["noise_contrast"]
    )
    build_waveform(PARAMS["waveform"])

    path = nb_common.save_blend(f"face_state_{STATE}.blend")
    print(f"[face_states] {STATE} built and saved: {path}")


main()
