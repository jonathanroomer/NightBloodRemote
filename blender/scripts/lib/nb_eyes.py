"""NightBlood eye system.

Face spec 5.2: warm ivory (#EFE6C8 anchor), almond shape, no pupils or iris.
Expression comes from aperture, tilt, asymmetry and gaze. In Blender the eyes
exist for look-dev, motion studies and target renders; at runtime the eyes are
always rendered live (never baked into loops).

Controls exposed as plain functions (deterministic keyframes, no drivers):
- set_aperture(rig_objects, value)
- set_gaze(rig, x, y)
- add_blink_keys(rig_objects, frame_start, frame_end, fps, seed, ...)
"""

from __future__ import annotations

import math
import random

import bpy

from nb_common import (
    EYE_CORE_WARM,
    EYE_EDGE_AMBER,
    ensure_collection,
    link_object,
    make_empty,
    new_node_material,
)

EYE_RIG_LOCATION = (0.0, -0.15, 0.94)
# Proportions measured from the primary reference: eye width ~ body width/6.2,
# inner gap ~ 0.66 eye widths. Body ~2 m wide -> eye width 0.32 m.
EYE_SEPARATION = 0.265  # metres from centre line to each eye centre
EYE_HALF_WIDTH = 0.16
# Slight asymmetry is part of the character (spec 4.1: "slightly asymmetric in
# tilt"). Reference reading (corrected against the design reference image
# 2026-08-10): outer corners slope gently DOWN — calm and heavy-lidded, never
# angry. Angles in degrees about the eye's depth axis.
EYE_TILT_LEFT = -6.0
EYE_TILT_RIGHT = 4.5

APERTURE_MIN_SCALE = 0.045  # never collapse to zero; a closed eye is a dim slit


def _almond_outline(segments: int = 48, h_up: float = 0.42, h_lo: float = 0.26):
    """Closed almond outline in the XZ plane, unit half-width.

    Exponents > 1 give pointed corners (horizontal tangent at the tips) like
    the reference; the top lid arches more than the bottom."""
    pts = []
    for i in range(segments + 1):  # top lid, left corner to right corner
        u = -1.0 + 2.0 * i / segments
        z = h_up * (1.0 - u * u) ** 1.35
        pts.append((u, z))
    for i in range(1, segments):  # bottom lid, right corner back to left
        u = 1.0 - 2.0 * i / segments
        z = -h_lo * (1.0 - u * u) ** 1.25
        pts.append((u, z))
    return pts


def _build_almond_mesh(name: str, scale: float, bulge: float) -> bpy.types.Mesh:
    outline = _almond_outline()
    mesh = bpy.data.meshes.new(name)
    verts = [(0.0, -bulge * scale, 0.0)]  # centre vertex, bulged toward camera
    for (u, z) in outline:
        r2 = min(1.0, u * u + (z / 0.4) ** 2)
        y = -bulge * scale * (1.0 - r2) * 0.5
        verts.append((u * scale, y, z * scale))
    n = len(outline)
    faces = [(0, 1 + i, 1 + ((i + 1) % n)) for i in range(n)]
    mesh.from_pydata(verts, [], faces)
    for poly in mesh.polygons:
        poly.use_smooth = True
    return mesh


def _eye_core_material() -> bpy.types.Material:
    mat = new_node_material("NB_EyeCore")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")

    # Warm gradient: bright ivory core falling to deep amber at the rim.
    tex = nodes.new("ShaderNodeTexCoord")
    grad = nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "SPHERICAL"
    mapping = nodes.new("ShaderNodeMapping")
    # Object coords are in metres; normalise to the eye's half-width so the
    # gradient spans the almond regardless of aperture scaling. Most of the
    # almond stays bright; the amber falloff lives only at the rim.
    inv = 1.0 / EYE_HALF_WIDTH
    mapping.inputs["Scale"].default_value = (inv * 0.55, inv * 0.55, inv * 1.35)

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = EYE_EDGE_AMBER
    ramp.color_ramp.elements[1].position = 0.35
    ramp.color_ramp.elements[1].color = (1.0, 0.90, 0.68, 1.0)

    # Kept low enough that AgX preserves the warm ivory instead of clipping
    # the core to clinical white.
    strength = nodes.new("ShaderNodeMapRange")
    strength.inputs["From Min"].default_value = 0.0
    strength.inputs["From Max"].default_value = 1.0
    strength.inputs["To Min"].default_value = 2.2
    strength.inputs["To Max"].default_value = 8.5

    links.new(tex.outputs["Object"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], grad.inputs["Vector"])
    links.new(grad.outputs["Fac"], ramp.inputs["Fac"])
    links.new(grad.outputs["Fac"], strength.inputs["Value"])
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(strength.outputs["Result"], emit.inputs["Strength"])
    links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return mat


def _eye_halo_material() -> bpy.types.Material:
    """Soft small halo: additive-feeling glow card behind each eye."""
    mat = new_node_material("NB_EyeHalo")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (1.0, 0.89, 0.66, 1.0)
    transparent = nodes.new("ShaderNodeBsdfTransparent")
    mix = nodes.new("ShaderNodeMixShader")

    tex = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    inv = 1.0 / (EYE_HALF_WIDTH * 1.6)
    mapping.inputs["Scale"].default_value = (inv, inv, inv * 1.6)
    grad = nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "SPHERICAL"
    power = nodes.new("ShaderNodeMath")
    power.operation = "POWER"
    power.inputs[1].default_value = 4.0
    scale = nodes.new("ShaderNodeMath")
    scale.operation = "MULTIPLY"
    scale.inputs[1].default_value = 1.1  # restrained: no headlight flare

    links.new(tex.outputs["Object"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], grad.inputs["Vector"])
    links.new(grad.outputs["Fac"], power.inputs[0])
    links.new(power.outputs["Value"], scale.inputs[0])
    links.new(scale.outputs["Value"], mix.inputs["Fac"])
    links.new(transparent.outputs["BSDF"], mix.inputs[1])
    links.new(emit.outputs["Emission"], mix.inputs[2])
    links.new(mix.outputs["Shader"], out.inputs["Surface"])

    mat.surface_render_method = "BLENDED"
    return mat


def build_eyes(scene: bpy.types.Scene, aperture: float = 0.55) -> dict:
    """Build the eye rig. Returns dict with rig empty and eye objects."""
    coll = ensure_collection("NB_Eyes")
    rig = make_empty("NB_EyeRig", EYE_RIG_LOCATION, coll)
    rig["aperture"] = aperture
    rig["gaze_x"] = 0.0
    rig["gaze_y"] = 0.0

    core_mat = _eye_core_material()
    halo_mat = _eye_halo_material()
    eyes = {}
    for side, sign, tilt in (("L", -1.0, EYE_TILT_LEFT), ("R", 1.0, EYE_TILT_RIGHT)):
        mesh = _build_almond_mesh(f"NB_Eye{side}", EYE_HALF_WIDTH, bulge=0.10)
        eye = bpy.data.objects.new(f"NB_Eye{side}", mesh)
        eye.data.materials.append(core_mat)
        eye.location = (sign * EYE_SEPARATION, 0.0, 0.0)
        eye.rotation_euler = (0.0, math.radians(tilt), 0.0)
        eye.parent = rig
        link_object(eye, coll)
        eye.visible_shadow = False

        halo_mesh = _build_almond_mesh(f"NB_EyeHalo{side}", EYE_HALF_WIDTH * 1.5, bulge=0.0)
        halo = bpy.data.objects.new(f"NB_EyeHalo{side}", halo_mesh)
        halo.data.materials.append(halo_mat)
        halo.location = (sign * EYE_SEPARATION, 0.035, 0.0)
        halo.rotation_euler = (0.0, math.radians(tilt), 0.0)
        halo.parent = rig
        link_object(halo, coll)
        halo.visible_shadow = False
        halo.visible_glossy = False
        halo.visible_diffuse = False

        eyes[side] = {"eye": eye, "halo": halo}

    set_aperture(eyes, aperture)
    return {"rig": rig, "eyes": eyes, "collection": coll}


def _aperture_to_scale(value: float) -> float:
    return APERTURE_MIN_SCALE + (1.0 - APERTURE_MIN_SCALE) * max(0.0, min(1.0, value))


def set_aperture(eyes: dict, value: float, halo_follow: bool = True) -> None:
    s = _aperture_to_scale(value)
    for side in eyes.values():
        side["eye"].scale[2] = s
        if halo_follow:
            side["halo"].scale[2] = 0.35 + 0.65 * s


def set_gaze(rig: bpy.types.Object, x: float, y: float) -> None:
    """Small gaze shifts; x,y in [-1,1] map to a few degrees of rig rotation."""
    rig["gaze_x"] = x
    rig["gaze_y"] = y
    rig.rotation_euler = (math.radians(-4.0 * y), 0.0, math.radians(-6.0 * x))


def _key_eye_scales(eyes: dict, frame: int, aperture: float, lag_r: int = 1, close_bias_r: float = 0.92) -> None:
    s = _aperture_to_scale(aperture)
    for side_name, side in eyes.items():
        f = frame + (lag_r if side_name == "R" else 0)
        target = s if side_name == "L" else _aperture_to_scale(aperture * close_bias_r)
        side["eye"].scale[2] = target
        side["eye"].keyframe_insert("scale", index=2, frame=f)
        side["halo"].scale[2] = 0.35 + 0.65 * target
        side["halo"].keyframe_insert("scale", index=2, frame=f)


def add_blink_keys(
    eyes: dict,
    frame_start: int,
    frame_end: int,
    fps: int,
    base_aperture: float,
    seed: int,
    interval_s: tuple[float, float] = (4.0, 9.0),
    double_blink_p: float = 0.3,
) -> list[int]:
    """Naturalistic double-asymmetric blinks at irregular intervals.

    Returns blink start frames. Deterministic for a given seed.
    """
    rng = random.Random(seed)
    blink_frames = []
    t = frame_start + int(rng.uniform(*interval_s) * fps * 0.5)
    # A full blink (with double) spans up to 15 frames plus the right eye's
    # 1-frame lag; never let any key land past frame_end or the loop breaks.
    while t < frame_end - 20:
        _key_eye_scales(eyes, t, base_aperture)
        _key_eye_scales(eyes, t + 2, 0.0)  # close fast
        _key_eye_scales(eyes, t + 6, base_aperture)  # open slower
        blink_frames.append(t)
        if rng.random() < double_blink_p and t + 16 < frame_end - 20:
            _key_eye_scales(eyes, t + 8, base_aperture)
            _key_eye_scales(eyes, t + 10, base_aperture * 0.35)
            _key_eye_scales(eyes, t + 14, base_aperture)
        t += int(rng.uniform(*interval_s) * fps)
    # Hold the base aperture at range ends so loops close cleanly.
    _key_eye_scales(eyes, frame_start, base_aperture, lag_r=0, close_bias_r=1.0)
    _key_eye_scales(eyes, frame_end, base_aperture, lag_r=0, close_bias_r=1.0)
    return blink_frames
