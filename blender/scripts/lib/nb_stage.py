"""Base stage: camera, light rig, black stage with reflective floor.

Art direction (face spec 5.3/5.4):
- soft top-front key with shape, cool trace rims from behind the crests,
  strong negative fill (pure-black world, no ambient);
- faint floor reflection pool grounding the mass;
- camera at a gentle low angle, ~40 mm, subtle depth of field;
- image lives between roughly 2% and 30% luminance.
"""

from __future__ import annotations

import math

import bpy

from nb_common import (
    FLOOR_NEAR_BLACK,
    ensure_collection,
    link_object,
    make_empty,
    new_node_material,
    track_to,
)

# The organism occupies roughly a 2 m footprint centred at the origin, rising
# from the floor; the eyes sit near z = 0.94.
FOCUS_POINT = (0.0, 0.0, 0.92)


def build_world(scene: bpy.types.Scene) -> None:
    world = bpy.data.worlds.get("NB_World") or bpy.data.worlds.new("NB_World")
    scene.world = world
    world.use_nodes = True
    nodes = world.node_tree.nodes
    links = world.node_tree.links
    nodes.clear()
    bg = nodes.new("ShaderNodeBackground")
    bg.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    bg.inputs["Strength"].default_value = 0.0
    out = nodes.new("ShaderNodeOutputWorld")
    links.new(bg.outputs["Background"], out.inputs["Surface"])


def build_backdrop(collection: bpy.types.Collection) -> bpy.types.Object:
    """A huge card behind the organism carrying the faint smoky gradient of the
    reference background. Luminance stays in the 1-3% band."""
    mesh = bpy.data.meshes.new("NB_Backdrop")
    half_w, half_h = 14.0, 7.0
    y = 7.5
    mesh.from_pydata(
        [(-half_w, y, -0.5), (half_w, y, -0.5), (half_w, y, half_h), (-half_w, y, half_h)],
        [],
        [(0, 1, 2, 3)],
    )
    obj = bpy.data.objects.new("NB_Backdrop", mesh)
    link_object(obj, collection)

    mat = new_node_material("NB_BackdropMat")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")

    # Radial falloff centred a little above frame centre, broken by very large
    # soft noise so the background reads as smoky depth rather than a vignette.
    # Generated coords span the card's bounding box 0..1 (the quad has no UVs).
    # Centre the lift behind the organism's core (world z ~1.1 -> gen z 0.213)
    # with a tight elliptical radius so only the region around the mass lifts.
    tex_coord = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (6.0, 0.0, 4.5)
    mapping.inputs["Location"].default_value = (-3.0, 0.0, -0.96)
    grad = nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "SPHERICAL"
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 2.2
    noise.inputs["Detail"].default_value = 6.0
    noise.inputs["Roughness"].default_value = 0.55
    mixf = nodes.new("ShaderNodeMix")
    mixf.data_type = "FLOAT"
    mixf.inputs["Factor"].default_value = 0.45
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.0, 0.0, 0.0, 1.0)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.0085, 0.0080, 0.0105, 1.0)

    # Fade to black at the card's bottom so no floor/backdrop line shows.
    sep = nodes.new("ShaderNodeSeparateXYZ")
    zfade = nodes.new("ShaderNodeMapRange")
    zfade.inputs["From Min"].default_value = 0.02
    zfade.inputs["From Max"].default_value = 0.22
    zfade.clamp = True

    links.new(tex_coord.outputs["Generated"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], grad.inputs["Vector"])
    links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
    links.new(grad.outputs["Fac"], mixf.inputs["A"])
    links.new(noise.outputs["Fac"], mixf.inputs["B"])
    links.new(mixf.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(tex_coord.outputs["Generated"], sep.inputs["Vector"])
    links.new(sep.outputs["Z"], zfade.inputs["Value"])
    links.new(zfade.outputs["Result"], emit.inputs["Strength"])
    links.new(emit.outputs["Emission"], out.inputs["Surface"])

    obj.data.materials.append(mat)
    obj.visible_shadow = False
    return obj


def build_floor(collection: bpy.types.Collection) -> bpy.types.Object:
    mesh = bpy.data.meshes.new("NB_Floor")
    s = 16.0
    mesh.from_pydata(
        [(-s, -s, 0.0), (s, -s, 0.0), (s, s, 0.0), (-s, s, 0.0)],
        [],
        [(0, 1, 2, 3)],
    )
    obj = bpy.data.objects.new("NB_Floor", mesh)
    link_object(obj, collection)

    mat = new_node_material("NB_FloorMat")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    # Dark mirror: reflections of the black world stay black, the eyes and
    # body read as a reflection pool, and almost nothing scatters diffusely.
    bsdf.inputs["Base Color"].default_value = (0.020, 0.020, 0.028, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.85
    bsdf.inputs["Roughness"].default_value = 0.12

    # Slight noise bump so the reflection pool breaks up organically.
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 9.0
    noise.inputs["Detail"].default_value = 8.0
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.03
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    # The pool vignettes into darkness with distance; no visible horizon.
    tex = nodes.new("ShaderNodeTexCoord")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    dist = nodes.new("ShaderNodeVectorMath")
    dist.operation = "LENGTH"
    fade = nodes.new("ShaderNodeMapRange")
    fade.inputs["From Min"].default_value = 3.0
    fade.inputs["From Max"].default_value = 9.0
    fade.clamp = True
    black = nodes.new("ShaderNodeEmission")
    black.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0)
    black.inputs["Strength"].default_value = 0.0
    mix = nodes.new("ShaderNodeMixShader")

    links.new(tex.outputs["Object"], dist.inputs[0])
    links.new(dist.outputs["Value"], fade.inputs["Value"])
    links.new(fade.outputs["Result"], mix.inputs["Fac"])
    links.new(bsdf.outputs["BSDF"], mix.inputs[1])
    links.new(black.outputs["Emission"], mix.inputs[2])
    links.new(mix.outputs["Shader"], out.inputs["Surface"])
    obj.data.materials.append(mat)
    return obj


def build_camera(scene: bpy.types.Scene, collection: bpy.types.Collection, focus: bpy.types.Object) -> bpy.types.Object:
    cam_data = bpy.data.cameras.new("NB_Camera")
    cam_data.lens = 40.0
    cam_data.sensor_width = 36.0
    cam_data.dof.use_dof = True
    cam_data.dof.focus_object = focus
    cam_data.dof.aperture_fstop = 4.0
    cam = bpy.data.objects.new("NB_Camera", cam_data)
    cam.location = (0.0, -3.15, 0.72)  # gentle low angle looking slightly up
    link_object(cam, collection)
    track_to(cam, focus)
    scene.camera = cam
    return cam


def _area_light(
    name: str,
    location,
    color,
    energy: float,
    size: float,
    size_y: float,
    collection,
    target,
) -> bpy.types.Object:
    data = bpy.data.lights.new(name, type="AREA")
    data.color = color
    data.energy = energy
    data.shape = "RECTANGLE"
    data.size = size
    data.size_y = size_y
    obj = bpy.data.objects.new(name, data)
    obj.location = location
    link_object(obj, collection)
    track_to(obj, target)
    return obj


def build_lights(collection: bpy.types.Collection, target: bpy.types.Object) -> dict:
    key = _area_light(
        "NB_Key", (0.5, -2.7, 3.7), (1.0, 0.97, 0.92), 220.0, 3.2, 2.4, collection, target
    )
    rim_l = _area_light(
        "NB_RimL", (-2.8, 2.3, 1.5), (0.72, 0.74, 1.0), 260.0, 0.6, 2.6, collection, target
    )
    rim_r = _area_light(
        "NB_RimR", (2.8, 2.3, 1.65), (0.78, 0.72, 1.0), 230.0, 0.6, 2.6, collection, target
    )
    return {"key": key, "rim_l": rim_l, "rim_r": rim_r}


def build_stage(scene: bpy.types.Scene) -> dict:
    """Build the full empty stage. Returns the created objects."""
    stage = ensure_collection("NB_Stage")
    build_world(scene)
    focus = make_empty("NB_Focus", FOCUS_POINT, stage)
    objs = {
        "focus": focus,
        "backdrop": build_backdrop(stage),
        "floor": build_floor(stage),
        "camera": build_camera(scene, stage, focus),
    }
    objs.update(build_lights(stage, focus))
    return objs
