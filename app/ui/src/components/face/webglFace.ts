/**
 * WebGL2 renderer: the entire face in one fragment shader — near-black
 * drifting background, warm-ivory SDF almond eyes (same lid-curve math as
 * the Blender rig in nb_eyes.py), and a floor band with a faint eye
 * reflection. Speech is shown by what the creature and its surroundings do —
 * see the speech uniforms below and SPEAKING_CONCEPTS.md.
 *
 * The Blender production renders are the look target; constants here are
 * tuned A/B against blender/renders/face_idle/hero_f200_.png.
 */

import type { FaceUniforms } from "./faceDirector";

/**
 * Speaking concepts, switchable so they can be compared rather than argued
 * about. Values mirror the SPEAK_* constants in the fragment shader.
 * LID and STILL are handled by the director, not the shader.
 */
export const SPEAK = {
  HAZE: 1,      // A: the darkness churns
  HALO: 2,      // B: the eye halos swell
  TREMOR: 4,    // C: a fine vibration
  LID: 8,       // D: lids articulate on stress   (director)
  FLOOR: 16,    // E: the floor answers
  THERMAL: 32,  // F: the eyes run hotter
  STILL: 64,    // G: everything else quiets      (director)
  MOUTH: 128,   // H: the mouth opens with the voice
} as const;

const VERT = `#version 300 es
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
out vec4 outColor;

uniform vec2 uResolution;
// Origin of this draw's tile in window coordinates. gl_FragCoord is always
// window-relative, so tiling several faces into one canvas needs this to be
// subtracted; it is (0,0) for a normal full-canvas render.
uniform vec2 uOrigin;
uniform float uApertureL, uApertureR;
uniform float uEyeGain;
uniform vec2 uGaze, uGazeL, uGazeR;
uniform float uTiltL, uTiltR;
uniform float uSquintL, uSquintR;
// State colour lives in the EYES, not the backdrop. Tinting the smoke floods
// the frame and throws away the dark-on-dark design; a cool glow coming off
// the eyes is both more visible and more in character. The halo takes more of
// the tint than the core, so at low amounts the colour reads as a glow around
// the eye rather than a repaint of it.
uniform vec3 uEyeTint;
uniform float uEyeTintAmt;
// One-shot Voice-ready acknowledgement. Unlike state tint, this colours only
// the almond itself; the surrounding halo and floor reflection stay ivory.
uniform float uReadyFlash;
// Telemetry, not expression: how much the camera can see. 0..1 each.
uniform float uSeen;
uniform float uLooking;
// How far gaze translates the eye, in frame widths. The original (0.020,
// 0.012) moved the almond by ~15% of its own half-width, which is why the
// face read as two parked lights: the eyes were genuinely looking around and
// you could not see it. Tunable so the lab can A/B the magnitude.
uniform vec2 uGazeTravel;
uniform float uDriftPhase1, uDriftPhase2, uDriftRadius;
uniform float uNoiseContrast, uBackdropGain, uVioletMix, uRedMix;
uniform float uWave[64];    // scrolling authorised-amplitude history

// --- speech ---------------------------------------------------------------
// NightBlood has no mouth, so speech is shown by what the creature and its
// surroundings DO, never by a shape opening and closing. Each concept is
// switchable so they can be compared in the face lab; see
// docs/reference/face/SPEAKING_CONCEPTS.md.
uniform float uSpeak;       // shaped envelope, 0..1 (fast attack, slow release)
uniform float uSpeakPhase;  // integrates with speech, so churn never jumps
uniform float uTime;
uniform int uSpeakMask;

const int SPEAK_HAZE    = 1;   // A: the darkness churns
const int SPEAK_HALO    = 2;   // B: the eye halos swell
const int SPEAK_TREMOR  = 4;   // C: a fine vibration
const int SPEAK_FLOOR   = 16;  // E: the floor answers
const int SPEAK_THERMAL = 32;  // F: the eyes run hotter
const int SPEAK_MOUTH   = 128; // H: the mouth opens with the voice
// D (lid articulation) and G (stillness) live in the director, not here.

float speakAmt(int flag) { return (uSpeakMask & flag) != 0 ? uSpeak : 0.0; }

const vec3 BASE = vec3(0.0085, 0.0080, 0.0105);
const vec3 VIOLET = vec3(0.0095, 0.0070, 0.0165);
const vec3 RED = vec3(0.0135, 0.0038, 0.0040);
const vec3 CORE_WARM = vec3(0.98, 0.88, 0.67);
const vec3 EDGE_AMBER = vec3(0.72, 0.58, 0.34);
const vec3 READY_GREEN = vec3(0.015, 1.0, 0.12);

vec3 readySaturation(vec3 colour, float amount) {
  float luma = dot(colour, vec3(0.2126, 0.7152, 0.0722));
  vec3 saturated = vec3(luma) + (colour - vec3(luma)) * 2.25;
  return max(vec3(0.0), mix(colour, saturated, amount));
}

const float EYE_SEP = 0.146;     // of frame width, centre to each eye
const float EYE_HALF_W = 0.082;  // of frame width
const float EYE_Y = 0.032;       // above frame centre
const float FLOOR_Y = -0.30;
const float MOUTH_Y = -0.191;    // 0.42m below the eyes in the Blender stage
// Measured off the Blender original (build_face_states.py:build_waveform), which
// is the design authority: a ribbon 0.98m wide and 0.028m tall at its loudest
// sample, sitting 0.42m below the eyes. Converting through the eye geometry
// (Blender EYE_SEPARATION 0.265 <-> shader EYE_SEP 0.146, so x0.53) gives the
// numbers below. The WebGL version had drifted to roughly an eighth the width
// and eight times the height of that, which is why it read as a blob where the
// reference reads as a line — 19 times wider than tall is the whole character.
// Pupil to pupil. The Blender ribbon is 0.98m — wider than both eyes together,
// which full-screen crossed most of the panel. A mouth as wide as the eyes are
// apart is what a face actually does.
const float MOUTH_HALF_W = EYE_SEP;
const float MOUTH_HEIGHT = 0.042;
const float MOUTH_BELOW = 0.85;  // the trough side is shorter than the crest

float hash31(vec3 p) {
  p = fract(p * vec3(234.34, 435.345, 171.13));
  p += dot(p, p.yzx + 34.23);
  return fract((p.x + p.y) * p.z);
}
float vnoise3(vec3 p) {
  vec3 i = floor(p), f = fract(p);
  vec3 u = f * f * (3.0 - 2.0 * f);
  float n000 = hash31(i), n100 = hash31(i + vec3(1, 0, 0));
  float n010 = hash31(i + vec3(0, 1, 0)), n110 = hash31(i + vec3(1, 1, 0));
  float n001 = hash31(i + vec3(0, 0, 1)), n101 = hash31(i + vec3(1, 0, 1));
  float n011 = hash31(i + vec3(0, 1, 1)), n111 = hash31(i + vec3(1, 1, 1));
  return mix(
    mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
    mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}
// Evolving fbm: w advances with time, so the pattern churns rather than
// merely translating (the "living" quality; mirrors nb_drift.py).
//
// Spatial and temporal frequency are advanced SEPARATELY. The obvious way to
// write this — scaling a vec3(p, w) by 2.1 each octave — also multiplies the
// time axis, so the finest octave evolved 2.1^4 ≈ 19x faster than the base and
// the smoke boiled rather than flowed. Detail should get finer without getting
// faster: that is the difference between sloshing and seething.
float fbm(vec2 p, float w) {
  float v = 0.0, a = 0.55;
  vec2 q = p;
  float t = w;
  for (int i = 0; i < 5; i++) {
    v += a * vnoise3(vec3(q, t));
    q = q * 2.1 + 17.7;   // spatial detail doubles each octave...
    t = t * 1.15 + 5.3;   // ...while time barely speeds up (1.75x at octave 5)
    a *= 0.5;
  }
  return v;
}

// Almond lids — identical curve family to nb_eyes._almond_outline, with a
// squint term: tension flattens the top arch and raises the lower lid, the
// way a real eye narrows. Squint 0 reproduces the original curves exactly.
float lidTop(float u, float sq) {
  return (0.42 - 0.15 * sq) * pow(max(0.0, 1.0 - u * u), 1.35 + 0.45 * sq);
}
float lidBot(float u, float sq) {
  return (0.26 - 0.10 * sq) * pow(max(0.0, 1.0 - u * u), 1.25);
}

// Returns: x = inside factor (AA), y = radial gradient fac, z = halo field.
vec3 eyeField(vec2 p, vec2 centre, float tilt, float aperture, float squint, float turn) {
  vec2 q = p - centre;
  float c = cos(tilt), s = sin(tilt);
  q = vec2(c * q.x + s * q.y, -s * q.x + c * q.y);
  // Foreshortening: an eye turned away from the viewer presents a narrower
  // almond. Small, but it stops a hard sideways look reading as the whole
  // face sliding sideways.
  float halfW = EYE_HALF_W * (1.0 - 0.16 * min(1.0, abs(turn)));
  float u = q.x / halfW;
  float ap = max(aperture, 0.045);
  float y = q.y / (halfW * ap);
  float top = lidTop(u, squint) - y;
  float bot = y + lidBot(u, squint);
  float inside = min(min(top, bot), 1.0 - abs(u));
  float aa = fwidth(inside) * 1.5;
  float inFac = smoothstep(-aa, aa, inside);
  // The emission gradient leans the way the eye is looking. This is not a
  // pupil (the design has none, see nb_eyes.py) — the almond stays uniform in
  // shape and only the brightest part of the glow shifts, which is what sells
  // direction on a face that has nothing else to point with.
  float rad = length(vec2((u - turn * 0.30) * 0.55, y * 0.30));
  float fac = clamp(1.0 - rad, 0.0, 1.0);
  // Halo: soft elliptical falloff outside the almond.
  // B: speech widens and softens it, so energy reads as radiating from behind
  // the eyes. The almond itself never moves — that is the whole point.
  float swell = speakAmt(SPEAK_HALO);
  float hd = length(vec2(q.x / (halfW * (1.55 + 0.34 * swell)),
                         q.y / (halfW * (0.95 + 0.22 * swell) * (0.35 + 0.65 * ap))));
  float halo = exp(-hd * hd * (5.5 - 1.15 * swell)) * (1.0 - inFac);
  return vec3(inFac, fac, halo);
}

// The mouth: the original scrolling waveform, restored. Slice 2 retired it on
// the argument that a face with no mouth should not grow one to speak — but
// full-screen on the Pi its absence read as a gap, and the almond that briefly
// replaced it was a mouth even when silent, which is worse. This one does not
// exist unless there is a voice: below the threshold it returns nothing at all.
//
// Newest sample at the centre, ageing outward symmetrically, so it reads as
// energy radiating from the voice rather than as a bar scrolling past.
float waveform(vec2 p, float level) {
  if (level <= 0.001) return 0.0;
  if (abs(p.x) > MOUTH_HALF_W) return 0.0;
  float u = p.x / MOUTH_HALF_W;
  float idx = 63.0 - abs(u) * 63.0;
  int i0 = int(floor(idx));
  float amp = mix(uWave[i0], uWave[min(i0 + 1, 63)], fract(idx));
  // Jagged, in the character of the Blender profile: that one is a wandering
  // height normalised so its own peak is full height, so it reaches near zero
  // between spikes. The 0.10 floor here did the opposite — it guaranteed a
  // continuous band, which reads as a line with texture on it rather than as a
  // waveform. Two frequencies, sharpened, dropping to nothing in the troughs.
  //
  // The envelope stays truthful — height is the real authorised level — while
  // the profile is invented. Blender's is seeded rather than sampled too: this
  // has always mimicked a waveform, and only claims to.
  float j1 = vnoise3(vec3(p.x * 260.0, 7.0, uDriftPhase1 * 6.0));
  float j2 = vnoise3(vec3(p.x * 71.0, 19.0, uDriftPhase1 * 2.7));
  float jag = clamp(pow(j1, 1.6) * (0.30 + 0.70 * j2) * 3.2, 0.0, 1.0);
  // An aperture, not a trace. Spreading the voice's history along x is what a
  // waveform is, and it reads as a meter however ragged you make it — so the
  // silhouette is the eyes' own lid curve family instead, opening with the
  // level. Tapering to points at both ends means no horizontal edge exists at
  // any volume, and the ragged multiplier keeps the outline off any flat line.
  float lens = pow(max(0.0, 1.0 - u * u), 1.7);
  // The trough floor thins toward the corners, so the tapering ends break into
  // fragments instead of drawing out into the sliver that reads as a line.
  float floorAmt = mix(0.30, 0.0, abs(u));
  float h = level * MOUTH_HEIGHT * lens * (0.55 + 0.45 * amp)
            * (floorAmt + (1.0 - floorAmt) * jag);
  if (h <= 1e-5) return 0.0;
  // Asymmetric about its own line, as the Blender ribbon is: crest full height,
  // trough 85% of it.
  float dy = p.y - MOUTH_Y;
  float hh = dy > 0.0 ? h : h * MOUTH_BELOW;
  return smoothstep(hh, hh * 0.35, abs(dy));
}

vec3 renderEyes(vec2 p, float reflected) {
  float apL = reflected > 0.5 ? uApertureL * 0.9 : uApertureL;
  float apR = reflected > 0.5 ? uApertureR * 0.9 : uApertureR;
  vec3 col = vec3(0.0);
  for (int i = 0; i < 2; i++) {
    float side = i == 0 ? -1.0 : 1.0;
    vec2 g = i == 0 ? uGazeL : uGazeR;
    vec3 f = eyeField(
      p, vec2(side * EYE_SEP, EYE_Y) + g * uGazeTravel,
      i == 0 ? uTiltL : uTiltR,
      i == 0 ? apL : apR,
      i == 0 ? uSquintL : uSquintR,
      g.x);
    float ramp = smoothstep(0.0, 0.35, f.y);
    // F: voiced sound runs the core hotter — a temperature change rather than
    // a movement. Deliberately small; colour flicker is unpleasant.
    vec3 core = mix(CORE_WARM, vec3(1.0, 0.965, 0.90), speakAmt(SPEAK_THERMAL) * 0.75);
    vec3 edge = EDGE_AMBER;
    vec3 haloCol = vec3(1.0, 0.88, 0.62);
    // State tint. The core has to take almost all of it: leaving even 30% of
    // the warm ivory in desaturates the result to a dull lilac, which is the
    // opposite of the intent. The rim goes darker and fully saturated so the
    // eye reads as coloured light rather than a white eye behind a filter.
    // Taken all the way: the last 4% of warm ivory is mostly green, and green
    // is exactly what a violet cannot afford on a panel this cheap.
    core = mix(core, uEyeTint, uEyeTintAmt);
    edge = mix(edge, uEyeTint * 0.50, uEyeTintAmt);
    haloCol = mix(haloCol, uEyeTint, uEyeTintAmt);
    // Positive ready acknowledgement: repaint only the filled almond, never
    // the halo. Reflections stay untouched so the green reads as the creature
    // meeting your eyes, not the whole room changing colour.
    float ready = reflected > 0.5 ? 0.0 : uReadyFlash;
    core = mix(core, READY_GREEN, ready);
    edge = mix(edge, READY_GREEN * 0.58, ready);
    core = readySaturation(core, ready);
    edge = readySaturation(edge, ready);
    vec3 eyeCol = mix(edge, core, ramp);
    float strength = mix(0.55, 1.0, f.y);
    col += eyeCol * strength * f.x;
    col += haloCol * f.z * (0.22 + 0.26 * speakAmt(SPEAK_HALO));
  }
  return col * uEyeGain;
}


void main() {
  vec2 uv = (gl_FragCoord.xy - uOrigin) / uResolution;
  float aspect = uResolution.x / uResolution.y;
  // Frame space: x in [-0.5, 0.5] of width, y scaled to match.
  vec2 p = (uv - 0.5) * vec2(1.0, 1.0 / aspect);

  // C: tremor. Not displacement you could track — a shimmer. Tiny on purpose;
  // much more than this and it reads as a rendering fault rather than a voice.
  float tremor = speakAmt(SPEAK_TREMOR);
  if (tremor > 0.0) {
    p += vec2(sin(uTime * 57.0), cos(uTime * 79.0)) * tremor * 0.0015
       + vec2(sin(uTime * 113.0 + 1.7), cos(uTime * 97.0)) * tremor * 0.0007;
  }

  // Background: radial lift centred above the eyes + two drifting layers.
  vec2 dp1 = uDriftRadius * vec2(cos(uDriftPhase1), sin(uDriftPhase1));
  vec2 dp2 = uDriftRadius * 0.6 * vec2(cos(uDriftPhase2), sin(uDriftPhase2));
  // Gaussian lift: no boundary anywhere, so the background can never read
  // as a defined shape. Noise shapes the interior; a whisper of it remains
  // in the corners so darkness stays organic.
  vec2 gq = (p - vec2(0.0, 0.06)) * vec2(2.0, 3.4);
  float grad = exp(-dot(gq, gq) * 1.6);
  // A: the darkness speaks. uSpeakPhase integrates with the voice, so the
  // churn accelerates while talking and never jumps when the level changes.
  float haze = speakAmt(SPEAK_HAZE);
  float n1 = fbm(p * 4.4 + dp1 * 3.0, uDriftPhase1 * 0.20 + uSpeakPhase * 0.34);
  float n2 = fbm(p * 7.2 + dp2 * 3.0 + 41.3, uDriftPhase2 * 0.16 + uSpeakPhase * 0.24);
  float noiseMix = mix(n1, n2, 0.4);
  // Structure carries the backdrop; the pedestal only lifts it. 0.43 of flat
  // lift was most of the brightness and none of the movement, which is exactly
  // what reads as a grey wash — so pedestal down, noise up: same peaks, far
  // darker troughs, smoke over black rather than haze over grey.
  float interior = 0.07 + (2.30 + 0.85 * haze) * noiseMix
                   * clamp(0.55 * uNoiseContrast, 0.0, 1.0);
  // The ambient term keeps darkness organic rather than flat, but full-bleed
  // it covers the entire panel, and gamma encoding lifts even 0.4% linear to a
  // visible grey. Smoke belongs over the black, not instead of it.
  float field = grad * interior + 0.014 * noiseMix * uNoiseContrast;
  // Breathing: huge slow luminance roll, like darkness gently moving.
  float breathe = 0.82 + 0.38 * vnoise3(vec3(p * 0.9, uDriftPhase2 * 0.16 + 7.7));
  vec3 tint = BASE + (VIOLET - BASE) * uVioletMix + (RED - BASE) * uRedMix;
  // Boxed, the canvas edge was masked into the page and the corners were never
  // seen. Full-bleed the frame edge is the bezel, so a backdrop still lit out
  // there reads as a grey panel rather than an unlit room — and on the Pi's IPS
  // that is far more obvious than on the laptop. Fall to true black well inside
  // the edge. Measured in frame coordinates, so it holds at any aspect.
  float vign = smoothstep(0.88, 0.12, length((uv - 0.5) * 2.0));
  vec3 bg = tint * field * breathe * uBackdropGain * 1.65 * vign;
  // Bottom fade into the floor band.
  bg *= smoothstep(-0.5, FLOOR_Y + 0.10, p.y);

  // Floor: cool dark band with a faint blurred eye reflection.
  float floorFac = smoothstep(FLOOR_Y + 0.02, FLOOR_Y - 0.06, p.y);
  vec3 floorCol = vec3(0.010, 0.011, 0.016) * (0.6 + 0.4 * uBackdropGain);
  // E: the floor answers — speech disturbs the world beneath the creature
  // rather than the creature itself.
  float ripple = speakAmt(SPEAK_FLOOR);
  vec2 mirrored = vec2(p.x, 2.0 * FLOOR_Y - p.y + 0.10);
  mirrored.y += sin(p.x * 34.0 + uTime * 6.5) * 0.005 * ripple;
  vec3 refl = renderEyes(mirrored, 1.0) * (0.045 + 0.075 * ripple);
  vec3 col = mix(bg, floorCol + refl, floorFac);

  col += renderEyes(p, 0.0);
  // White, not the old warm gold: against ivory eyes the copper read as a
  // second, dimmer light source rather than as the voice.
  col += vec3(1.0) * waveform(p, speakAmt(SPEAK_MOUTH)) * 0.85;

  // Gentle highlight roll approximating the AgX shoulder.
  col = col / (1.0 + 0.35 * col);
  // The rolloff compresses bright channels toward each other, so it greys a
  // saturated colour precisely where it is most intense — the eye core. Push
  // saturation back afterwards, in proportion to how tinted the state is.
  // Raised from 1.55 for the Pi: the panel's own colour volume takes another
  // bite out of the hue, and violet that reads clearly on the laptop arrives
  // there as a pale blue-grey. The state colour has to survive the worst
  // screen it will be seen on, not the best.
  if (uEyeTintAmt > 0.0) {
    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(col, vec3(luma) + (col - vec3(luma)) * 2.25, uEyeTintAmt);
  }
  // Telemetry, not expression: a strip along the very bottom edge saying what
  // the camera can see. Dim green means a face is detected; bright means that
  // face is turned towards it. It exists because the face has plenty of idle
  // motion of its own, so without it there is no way to tell a real reaction
  // from a coincidence — and a behaviour tuned against a coincidence is worse
  // than one that was never built. Its own element rather than a tint on the
  // floor band, which at this aspect is 84% off the bottom of the panel.
  // The two levels have to be unmistakable at a glance, not merely different:
  // 0.30 vs 1.00 came out as 100 and 160 out of 255, which is a difference you
  // have to already know about to notice. Barely-there for "I can see someone",
  // unambiguous for "and they are looking at me".
  float strip = smoothstep(0.022, 0.0, uv.y);
  col += vec3(0.015, 0.42, 0.08) * strip * min(1.0, 0.10 * uSeen + 0.90 * uLooking);

  outColor = vec4(pow(col, vec3(1.0 / 2.2)), 1.0);
}`;

export class FaceRenderer {
  private gl: WebGL2RenderingContext;
  private program: WebGLProgram;
  private uniforms: Record<string, WebGLUniformLocation | null> = {};
  /** Frame-widths of eye translation at full gaze deflection. See uGazeTravel. */
  gazeTravel: [number, number] = [0.052, 0.028];
  /**
   * Which speaking concepts are active. Default A+H: the haze churns and the
   * mouth opens. B (halo swell) shipped first and is now off — with a mouth
   * carrying the voice, swelling the eyes as well read as too heavy, the eyes
   * appearing to vibrate. C (tremor) was cut earlier for looking like a
   * rendering fault. The rest stay switchable — see SPEAKING_CONCEPTS.md.
   */
  speakMask: number = SPEAK.HAZE | SPEAK.MOUTH;
  /** Scrolling authorised-amplitude history, newest last. Feeds the waveform. */
  private waveHistory = new Float32Array(64);

  constructor(canvas: HTMLCanvasElement) {
    const gl = canvas.getContext("webgl2", { antialias: true, alpha: false });
    if (!gl) throw new Error("WebGL2 unavailable");
    this.gl = gl;
    this.program = this.link(VERT, FRAG);
    for (const name of [
      "uResolution", "uOrigin", "uApertureL", "uApertureR", "uEyeGain",
      "uGaze", "uGazeL", "uGazeR", "uGazeTravel", "uTiltL", "uTiltR", "uSquintL", "uSquintR",
      "uDriftPhase1", "uDriftPhase2", "uDriftRadius", "uNoiseContrast",
      "uBackdropGain", "uVioletMix", "uRedMix",
      "uSpeak", "uSpeakPhase", "uSpeakMask", "uTime", "uEyeTint", "uEyeTintAmt",
      "uReadyFlash", "uSeen", "uLooking",
      "uWave",
    ]) {
      this.uniforms[name] = gl.getUniformLocation(this.program, name);
    }
  }

  private link(vertSrc: string, fragSrc: string): WebGLProgram {
    const gl = this.gl;
    const compile = (type: number, src: string) => {
      const sh = gl.createShader(type);
      if (!sh) throw new Error("shader alloc failed");
      gl.shaderSource(sh, src);
      gl.compileShader(sh);
      if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
        throw new Error(gl.getShaderInfoLog(sh) ?? "shader compile failed");
      }
      return sh;
    };
    const program = gl.createProgram();
    if (!program) throw new Error("program alloc failed");
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertSrc));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragSrc));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) ?? "program link failed");
    }
    return program;
  }

  /**
   * Draw one face. `ox`/`oy` place it inside a larger canvas, which lets the
   * face lab tile many frames of motion into a single GL context instead of
   * burning one context per tile (browsers cap those at around 16).
   */
  render(
    u: FaceUniforms,
    width: number,
    height: number,
    ox = 0,
    oy = 0,
    readyFlash = 0,
  ): void {
    const gl = this.gl;
    gl.viewport(ox, oy, width, height);
    gl.useProgram(this.program);
    gl.uniform2f(this.uniforms.uResolution, width, height);
    gl.uniform2f(this.uniforms.uOrigin, ox, oy);
    gl.uniform1f(this.uniforms.uApertureL, u.apertureL);
    gl.uniform1f(this.uniforms.uApertureR, u.apertureR);
    gl.uniform1f(this.uniforms.uEyeGain, u.eyeGain);
    gl.uniform2f(this.uniforms.uGaze, u.gazeX, u.gazeY);
    gl.uniform2f(this.uniforms.uGazeL, u.gazeLX, u.gazeLY);
    gl.uniform2f(this.uniforms.uGazeR, u.gazeRX, u.gazeRY);
    gl.uniform2f(this.uniforms.uGazeTravel, this.gazeTravel[0], this.gazeTravel[1]);
    gl.uniform1f(this.uniforms.uTiltL, u.tiltL);
    gl.uniform1f(this.uniforms.uTiltR, u.tiltR);
    gl.uniform1f(this.uniforms.uSquintL, u.squintL);
    gl.uniform1f(this.uniforms.uSquintR, u.squintR);
    gl.uniform3f(this.uniforms.uEyeTint, u.eyeTint[0], u.eyeTint[1], u.eyeTint[2]);
    gl.uniform1f(this.uniforms.uEyeTintAmt, u.eyeTintAmt);
    gl.uniform1f(this.uniforms.uReadyFlash, Math.min(1, Math.max(0, readyFlash)));
    gl.uniform1f(this.uniforms.uSeen, u.seen);
    gl.uniform1f(this.uniforms.uLooking, u.looking);
    gl.uniform1f(this.uniforms.uDriftPhase1, u.driftPhase1);
    gl.uniform1f(this.uniforms.uDriftPhase2, u.driftPhase2);
    gl.uniform1f(this.uniforms.uDriftRadius, u.driftRadius);
    gl.uniform1f(this.uniforms.uNoiseContrast, u.noiseContrast);
    gl.uniform1f(this.uniforms.uBackdropGain, u.backdropGain);
    gl.uniform1f(this.uniforms.uVioletMix, u.violet);
    gl.uniform1f(this.uniforms.uRedMix, u.red);
    gl.uniform1f(this.uniforms.uSpeak, u.speak);
    gl.uniform1f(this.uniforms.uSpeakPhase, u.speakPhase);
    gl.uniform1f(this.uniforms.uTime, u.time);
    gl.uniform1i(this.uniforms.uSpeakMask, this.speakMask);
    gl.uniform1fv(this.uniforms.uWave, this.waveHistory);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  /**
   * Push one authorised-amplitude sample into the scrolling waveform. Must be
   * the same level the director is given — the mouth is the voice made visible,
   * so a second, differently-sourced number here would be a face lying about
   * what it is hearing.
   */
  pushAmplitude(value: number): void {
    this.waveHistory.copyWithin(0, 1);
    this.waveHistory[63] = Math.min(1, Math.max(0, value));
  }

  /** This canvas is never reused after a face switch; release its GL slot. */
  dispose(): void {
    this.gl.deleteProgram(this.program);
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }
}
