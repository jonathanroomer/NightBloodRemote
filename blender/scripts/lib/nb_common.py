"""Shared constants and helpers for NightBlood Blender scripts.

All scene-building scripts import this module. Everything here must stay
deterministic: fixed seeds, fixed names, no wall-clock or environment
dependence.
"""

from __future__ import annotations

from pathlib import Path

import bpy

# blender/scripts/lib/nb_common.py -> repo root is three levels up from lib/.
LIB_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = LIB_DIR.parent
BLENDER_DIR = SCRIPTS_DIR.parent
REPO_ROOT = BLENDER_DIR.parent

PROFILES_DIR = BLENDER_DIR / "profiles"
BLENDS_DIR = BLENDER_DIR / "blends"
CACHE_DIR = BLENDER_DIR / "cache"
RENDERS_DIR = BLENDER_DIR / "renders"

GLOBAL_SEED = 1103

# The fourteen canonical states of engineering-spec 13.4. Asset names must use
# exactly these strings.
STATE_NAMES = [
    "offline",
    "starting",
    "idle",
    "listening",
    "transcribing",
    "routing",
    "thinking",
    "working",
    "speaking",
    "waiting_approval",
    "completed",
    "error",
    "event_gap",
    "degraded",
]

# Art-direction anchor values (section 5 of the face production spec).
EYE_IVORY = (0.937, 0.902, 0.784, 1.0)  # sRGB #EFE6C8 as float
EYE_CORE_WARM = (1.0, 0.94, 0.80, 1.0)
EYE_EDGE_AMBER = (0.72, 0.60, 0.38, 1.0)
BODY_BASE_NEAR_BLACK = (0.0086, 0.0086, 0.0122, 1.0)  # around #07070A, linearised
FLOOR_NEAR_BLACK = (0.010, 0.010, 0.014, 1.0)


def reset_to_empty_scene() -> bpy.types.Scene:
    """Start from a deterministic empty file."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.name = "NB_Scene"
    return scene


def ensure_collection(name: str, parent: bpy.types.Collection | None = None) -> bpy.types.Collection:
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        (parent or bpy.context.scene.collection).children.link(coll)
    return coll


def link_object(obj: bpy.types.Object, collection: bpy.types.Collection | None = None) -> None:
    target = collection or bpy.context.scene.collection
    if obj.name not in target.objects:
        target.objects.link(obj)


def make_empty(name: str, location=(0.0, 0.0, 0.0), collection=None) -> bpy.types.Object:
    empty = bpy.data.objects.new(name, None)
    empty.location = location
    empty.empty_display_size = 0.15
    link_object(empty, collection)
    return empty


def track_to(obj: bpy.types.Object, target: bpy.types.Object) -> None:
    con = obj.constraints.new(type="TRACK_TO")
    con.target = target
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"


def new_node_material(name: str) -> bpy.types.Material:
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.node_tree.nodes.clear()
    return mat


def save_blend(filename: str) -> Path:
    """Save the current file into blender/blends/."""
    BLENDS_DIR.mkdir(parents=True, exist_ok=True)
    path = BLENDS_DIR / filename
    bpy.ops.wm.save_as_mainfile(filepath=str(path), compress=True)
    return path
