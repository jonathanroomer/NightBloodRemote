# Creating a face with Blender and WebGL

The face workflow has two halves:

1. Blender is the visual laboratory: silhouette, eye geometry, light, drift,
   timing and expression are judged there.
2. WebGL is the shipping renderer: the accepted visual rules are rewritten as
   small state parameters and procedural shaders that respond in real time.

The repository includes scripts rather than `.blend` files. This makes every
scene reproducible and avoids publishing binary metadata, cached simulations,
absolute workstation paths or render output.

## Tools

- Blender 5.2 or later.
- Node.js 20.19 or later (or 22.12 or later) and npm for the live face.
- FFmpeg if you want MP4 review/soak clips.
- A GPU-capable browser or iOS Simulator for the runtime result.

From the repository root, choose your Blender binary. If `blender` is already
on `PATH`:

```bash
export BLENDER_BIN=blender
```

For the standard macOS application install:

```bash
export BLENDER_BIN=/Applications/Blender.app/Contents/MacOS/Blender
```

Generated files go under the ignored `blender/blends` and
`blender/renders` directories.

## 1. Build a stage study

The stage establishes a near-black world, backdrop, floor, camera and controlled
area lights. Render a single preview directly from source:

```bash
"$BLENDER_BIN" --background --python blender/scripts/render.py -- \
  --profile preview \
  --build blender/scripts/build_stage_still.py \
  --frames 1 \
  --out blender/renders/stage/frame_ \
  --format PNG
```

Use `preview` while composing, `preview_cycles` for a quick Cycles check and
`production` only for accepted studies. The JSON profiles pin resolution,
samples, colour management and output behaviour so comparisons remain useful.

## 2. Build NightBlood's idle scene

```bash
"$BLENDER_BIN" --background \
  --python blender/scripts/build_face_idle.py

"$BLENDER_BIN" --background --python blender/scripts/render.py -- \
  --profile preview \
  --blend blender/blends/face_idle.blend \
  --frames 1-360 \
  --out blender/renders/idle/idle_ \
  --format PNG
```

The idle loop is 360 frames at 30 fps. The noise texture travels around a
closed path, and blinks are seeded, so the study is reproducible. Judge the
eyes first: aperture, separation, gaze, warmth and halo. The dark material is
supporting atmosphere, not the subject.

The core construction libraries are:

- `nb_stage.py`: world, backdrop, camera, floor and lights;
- `nb_eyes.py`: almond meshes, emissive materials, gaze and blink keys;
- `nb_drift.py`: closed-loop background motion;
- `nb_common.py`: deterministic constants, scene reset and safe save paths.

## 3. Build every expression state

The state vocabulary lives in `blender/scripts/lib/nb_states.py`. Build one
state by setting two explicit environment values:

```bash
NB_STATE=thinking NB_LOOP_FRAMES=240 \
  "$BLENDER_BIN" --background \
  --python blender/scripts/build_face_states.py

"$BLENDER_BIN" --background --python blender/scripts/render.py -- \
  --profile preview \
  --blend blender/blends/face_state_thinking.blend \
  --frames 1-240 \
  --out blender/renders/state_loops/thinking_ \
  --format PNG
```

Available Blender states are `offline`, `starting`, `idle`, `listening`,
`transcribing`, `routing`, `thinking`, `working`, `speaking`,
`waiting_approval`, `completed`, `error`, `event_gap` and `degraded`.
`voice_working` is a live-only state in the current WebGL build.

To build and render all non-idle studies:

```bash
BLENDER_BIN="$BLENDER_BIN" \
  /bin/sh blender/scripts/render_state_loops_public.sh
```

That script also asks `make_clip.py` to create comparable 30 fps H.264 review
clips, so FFmpeg must be installed for the complete batch.

## 4. Check the loop, not just a still

An attractive frame can still produce an obvious pop. Play the clip three
times without a pause and inspect blinks, texture drift, waveform motion and
the final-to-first transition.

For the quantitative wrap check, run `nb_loop.seam_check` inside Blender:

```bash
"$BLENDER_BIN" --background --python-expr \
  "import sys; from pathlib import Path; sys.path.insert(0, 'blender/scripts/lib'); import nb_loop; print(nb_loop.seam_check(Path('blender/renders/state_loops'), 'thinking_', 1, 240, 'png'))"
```

A `seam_ratio` near 1 means the boundary moves by roughly a normal frame step;
the helper marks ratios below 2 as passing. Still watch the repeated clip:
image difference is evidence, not taste.

Create a three-cycle soak clip explicitly with:

```bash
python3 blender/scripts/make_clip.py \
  --seq blender/renders/state_loops/thinking_ \
  --start 1 \
  --count 240 \
  --repeat 3 \
  --out blender/renders/state_loops/thinking_soak.mp4
```

## 5. Translate the look to WebGL

Blender values are design measurements, not files to import. Move the accepted
rules deliberately:

| Blender judgement | Runtime destination |
|---|---|
| aperture, gaze, gain, blink policy | `stateParams.ts` |
| drift radius, loop rate, contrast | `stateParams.ts` and `faceDirector.ts` |
| eye shape, halo and backdrop material | `webglFace.ts` |
| transitions and micro-motion | `faceDirector.ts` |
| canonical state priority | `resolveVisualState.ts` |
| alternate character grammar | Marshmallow state/director/shader files |

Run the live renderer after each small translation:

```bash
npm --prefix app/ui ci
npm --prefix app/ui run typecheck
npm --prefix app/ui run dev
```

The native build uses `npm run build:ios-direct` and packages the resulting
single HTML bundle. Never add account data, task identity or network authority
to the renderer merely because JavaScript is convenient.

## Creating a genuinely new face

Start with character questions before shader questions:

1. What is its resting silhouette?
2. Which two or three motions make it feel alive?
3. How does listening differ from thinking without a label?
4. How does it ask for human attention?
5. What does failure look like without becoming alarming or misleading?
6. Which signal survives colour blindness and reduced motion?

Then implement the full contract:

1. Add a new value to `FACE_SKINS` and update parsing/selection helpers in
   `faceSkin.ts`.
2. Add a complete `Record<VisualState, ...>` parameter table. TypeScript should
   fail if any canonical state is missing.
3. Add a director that interpolates state changes and honours reduced motion.
4. Add the WebGL renderer and canvas wrapper.
5. Extend `FaceSurface.tsx` with an explicit branch.
6. Add the corresponding native `DirectFaceSkin` case, display name and picker
   option.
7. Add an original, bounded character prompt resource and include it in the
   XcodeGen source allowlist.
8. Test every state, face switching, foreground/background transitions,
   microphone amplitude, missing WebGL, stale state and a real error/recovery.

Do not clone another character by changing only its palette. Marshmallow uses
the same truthful state input as NightBlood, but has a body, bounce, squash,
smile and different eye grammar. That is the level of distinction to aim for.

## Accessibility and performance gates

- Honour `prefers-reduced-motion`; retain meaning with pose, brightness and
  shape rather than movement alone.
- Do not rely on colour as the only difference between working, waiting and
  failure.
- Clamp gaze and amplitude inputs and handle their absence.
- Test portrait sizes, Dynamic Type overlays and VoiceOver labels in native UI.
- Keep animation on `requestAnimationFrame`; avoid per-frame React state.
- Check shader compilation failure and a device without WebGL support.
- Profile on an older supported iPhone, not only a desktop browser.
- Confirm the face stops camera/media work when the app or session stops.

## What not to commit

Do not commit `.blend` files without manually inspecting their metadata and
licensing. Never commit render sequences, MP4 review clips, caches, absolute
paths, downloaded textures of uncertain origin, captured voices, Xcode
products or a designer's private reference material. The public audit rejects
the common binary forms intentionally.
