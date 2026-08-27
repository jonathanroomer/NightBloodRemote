"""Render profile application.

Profiles live as JSON in blender/profiles/ and are the only place where
resolution, engine, sampling, colour management (AgX) and motion blur are
defined. Scene scripts never hand-set these values (face spec 7.2).
"""

from __future__ import annotations

import json
from pathlib import Path

import bpy

from nb_common import PROFILES_DIR


def load_profile(name: str) -> dict:
    path = PROFILES_DIR / f"{name}.json"
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def enable_metal_gpu() -> list[str]:
    """Enable Metal GPU compute for Cycles. Returns enabled device names."""
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    try:
        prefs.refresh_devices()
    except AttributeError:
        prefs.get_devices()
    enabled = []
    for device in prefs.devices:
        device.use = True
        enabled.append(f"{device.name} ({device.type})")
    return enabled


def _build_glare_group(params: dict) -> bpy.types.NodeTree:
    """Build a minimal compositing node group: RenderLayers -> Glare -> Output.

    Blender 5.x compositing: the scene owns a compositing_node_group whose
    Group Output image socket is the final image.
    """
    name = "NB_Compositing"
    tree = bpy.data.node_groups.get(name)
    if tree is not None:
        bpy.data.node_groups.remove(tree)
    tree = bpy.data.node_groups.new(name, "CompositorNodeTree")
    tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")

    rlayers = tree.nodes.new("CompositorNodeRLayers")
    rlayers.location = (-300, 0)
    glare = tree.nodes.new("CompositorNodeGlare")
    glare.location = (0, 0)
    out = tree.nodes.new("NodeGroupOutput")
    out.location = (300, 0)

    # Restrained fog glow: the reference halo is small and soft. No heavy bloom.
    # Blender 5.x exposes glare controls as node input sockets.
    for key, value in (
        ("Type", "Fog Glow"),
        ("Quality", "High"),
        ("Threshold", params.get("threshold", 0.9)),
        ("Smoothness", 0.15),
        ("Strength", params.get("mix", 0.05)),
        ("Size", params.get("size", 0.6)),
    ):
        sock = glare.inputs.get(key)
        if sock is not None:
            try:
                sock.default_value = value
            except (TypeError, ValueError):
                pass

    tree.links.new(rlayers.outputs["Image"], glare.inputs["Image"])
    tree.links.new(glare.outputs["Image"], out.inputs["Image"])
    return tree


def apply_profile(scene: bpy.types.Scene, profile: dict) -> None:
    scene.render.engine = profile["engine"]
    scene.render.resolution_x, scene.render.resolution_y = profile["resolution"]
    scene.render.resolution_percentage = 100
    scene.render.fps = profile["fps"]

    if profile["engine"] == "CYCLES":
        devices = enable_metal_gpu()
        print(f"[nb_profiles] Cycles Metal devices enabled: {devices}")
        scene.cycles.device = "GPU"
        cyc = profile["cycles"]
        scene.cycles.samples = cyc["samples"]
        scene.cycles.use_adaptive_sampling = cyc.get("use_adaptive_sampling", True)
        scene.cycles.use_denoising = cyc.get("use_denoising", True)
        try:
            scene.cycles.denoiser = cyc.get("denoiser", "OPENIMAGEDENOISE")
        except TypeError:
            pass
        scene.render.use_motion_blur = profile.get("motion_blur", False)
        scene.render.motion_blur_shutter = profile.get("motion_blur_shutter", 0.5)
    else:
        eev = profile["eevee"]
        scene.eevee.taa_render_samples = eev["taa_render_samples"]
        if hasattr(scene.eevee, "use_raytracing"):
            scene.eevee.use_raytracing = eev.get("use_raytracing", True)
        scene.render.use_motion_blur = profile.get("motion_blur", False)
        if hasattr(scene.render, "motion_blur_shutter"):
            scene.render.motion_blur_shutter = profile.get("motion_blur_shutter", 0.5)

    color = profile["color"]
    scene.display_settings.display_device = color["display_device"]
    scene.view_settings.view_transform = color["view_transform"]
    scene.view_settings.look = color["look"]
    scene.view_settings.exposure = color["exposure"]
    scene.view_settings.gamma = color["gamma"]

    glare = profile.get("glare", {})
    if glare.get("enabled"):
        try:
            scene.compositing_node_group = _build_glare_group(glare)
            scene.render.use_compositing = True
        except Exception as exc:  # glare is polish, never a hard failure
            print(f"[nb_profiles] WARNING: compositor glare unavailable: {exc}")

    scene.render.film_transparent = False


def set_output(scene: bpy.types.Scene, filepath: str, fmt: str = "PNG") -> None:
    """Configure render output. fmt: PNG | PNG16 | EXR (multilayer half DWAA)."""
    scene.render.filepath = filepath
    img = scene.render.image_settings
    if fmt == "EXR":
        img.file_format = "OPEN_EXR_MULTILAYER"
        img.color_depth = "16"
        img.exr_codec = "DWAA"
    elif fmt == "EXR_SINGLE":
        img.file_format = "OPEN_EXR"
        img.color_depth = "16"
        img.exr_codec = "DWAA"
    elif fmt == "PNG16":
        img.file_format = "PNG"
        img.color_mode = "RGBA"
        img.color_depth = "16"
    else:
        img.file_format = "PNG"
        img.color_mode = "RGB"
        img.color_depth = "8"
