"""CLI render wrapper. The only sanctioned way to render NightBlood scenes.

Usage (always through Blender, headless):

  blender --background \
      --python blender/scripts/render.py -- \
      --profile production \
      [--blend blender/blends/foo.blend | --build blender/scripts/build_x.py] \
      --frames 1-300 | --frames 7 \
      --out blender/renders/foo/frame_ \
      --format PNG|PNG16|EXR|EXR_SINGLE

Profiles pin engine, resolution, sampling, AgX and motion blur (spec 7.2);
scene scripts never set those. Build scripts are executed with exec() and must
leave the scene ready to render.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import bpy

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR / "lib"))

import nb_profiles  # noqa: E402


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(prog="render.py")
    parser.add_argument(
        "--profile", required=True, choices=["preview", "preview_cycles", "production"]
    )
    parser.add_argument("--blend", help=".blend file to open")
    parser.add_argument("--build", help="scene-building python script to execute")
    parser.add_argument("--frames", required=True, help="N or A-B")
    parser.add_argument("--out", required=True, help="output path prefix")
    parser.add_argument("--format", default="PNG", choices=["PNG", "PNG16", "EXR", "EXR_SINGLE"])
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()

    if args.blend:
        bpy.ops.wm.open_mainfile(filepath=str(Path(args.blend).resolve()))
    if args.build:
        build_path = Path(args.build).resolve()
        code = compile(build_path.read_text(encoding="utf-8"), str(build_path), "exec")
        exec(code, {"__file__": str(build_path), "__name__": "__main__"})

    scene = bpy.context.scene
    profile = nb_profiles.load_profile(args.profile)
    nb_profiles.apply_profile(scene, profile)

    out_prefix = str(Path(args.out).resolve())
    Path(out_prefix).parent.mkdir(parents=True, exist_ok=True)
    nb_profiles.set_output(scene, out_prefix, args.format)

    if "-" in args.frames:
        start, end = (int(x) for x in args.frames.split("-"))
    else:
        start = end = int(args.frames)
    scene.frame_start, scene.frame_end = start, end

    t0 = time.time()
    if start == end:
        scene.frame_set(start)
        bpy.ops.render.render(write_still=True)
        print(f"[render.py] still frame {start} -> {out_prefix} in {time.time() - t0:.1f}s")
    else:
        bpy.ops.render.render(animation=True)
        n = end - start + 1
        dt = time.time() - t0
        print(f"[render.py] {n} frames -> {out_prefix} in {dt:.1f}s ({dt / n:.1f}s/frame)")


if __name__ == "__main__":
    main()
