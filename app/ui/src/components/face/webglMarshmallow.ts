/**
 * Marshmallow in one WebGL2 fragment shader.
 *
 * The ball is genuinely shaded in 3D; eyes and mouth are unshaded spherical
 * decals. There is no white specular highlight. This mirrors the approved
 * Blender rules while remaining cheap enough for the Pi panel and portable to
 * a native Metal implementation.
 */

import type { MarshmallowUniforms } from "./marshmallowDirector";
import {
  MARSHMALLOW_BODY_RADIUS,
  MARSHMALLOW_COLOURS,
  MARSHMALLOW_FLOOR_Y,
} from "./marshmallowStateParams";

const VERT = `#version 300 es
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
out vec4 outColor;

uniform vec2 uResolution;
uniform vec2 uOrigin;
uniform float uTime;
uniform vec2 uBodyPosition;
uniform vec2 uBodyScale;
uniform float uTilt;
uniform vec2 uFaceDirection;
uniform float uEyeHeight;
uniform float uEyeAsymmetry;
uniform vec3 uEyeColour;
uniform float uEyeGain;
uniform float uSmile;
uniform float uMouthOpen;
uniform float uBodyGain;
uniform float uReadyFlash;
uniform float uSeen;
uniform float uLooking;

const float BODY_R = ${MARSHMALLOW_BODY_RADIUS.toFixed(3)};
const float FLOOR_Y = ${MARSHMALLOW_FLOOR_Y.toFixed(3)};
const vec3 BODY_TOP = vec3(${MARSHMALLOW_COLOURS.bodyTop.join(", ")});
const vec3 BODY_BOTTOM = vec3(${MARSHMALLOW_COLOURS.bodyBottom.join(", ")});
const vec3 INK = vec3(0.0025, 0.0018, 0.0045);
const vec3 READY_GREEN = vec3(0.02, 1.0, 0.12);

vec2 rotate2(vec2 p, float angle) {
  float c = cos(angle), s = sin(angle);
  return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float roundedBox(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float ellipse(vec2 p, vec2 radius) {
  return length(p / radius) - 1.0;
}

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise2(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1, 0)), u.x),
             mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), u.x), u.y);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uOrigin) / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec2 p = (uv * 2.0 - 1.0) * vec2(aspect, 1.0);

  // The same unlit black room as NightBlood: enough structure to stop it
  // reading as a flat CSS background, never enough to become a coloured room.
  float room = exp(-dot(p * vec2(0.48, 0.80), p * vec2(0.48, 0.80)) * 3.0);
  float grain = noise2(p * 3.0 + vec2(uTime * 0.012, -uTime * 0.008));
  vec3 col = vec3(0.0012, 0.0014, 0.0022) * room * (0.55 + 0.45 * grain);

  // Dark mirror floor and a soft contact shadow.
  float floorMask = 1.0 - smoothstep(FLOOR_Y - 0.075, FLOOR_Y + 0.035, p.y);
  vec3 floorCol = vec3(0.0045, 0.0060, 0.0110);
  float shadow = exp(-pow((p.x - uBodyPosition.x) / 0.34, 2.0)
                     -pow((p.y - FLOOR_Y) / 0.036, 2.0));
  floorCol *= 1.0 - 0.62 * shadow;
  col = mix(col, floorCol, floorMask);

  // A deliberately faint, diffuse reflection. It carries body colour, not a
  // white light source, and fades before it can become a second character.
  vec2 mirroredP = vec2(p.x, 2.0 * FLOOR_Y - p.y);
  vec2 mirroredLocal = rotate2(mirroredP - uBodyPosition, -uTilt)
    / (BODY_R * uBodyScale);
  float mirroredD = length(mirroredLocal);
  float mirroredMask = (1.0 - smoothstep(0.985, 1.025, mirroredD))
    * floorMask * smoothstep(-0.95, -0.38, p.y);
  vec3 reflectedBody = mix(BODY_BOTTOM, BODY_TOP,
    clamp(mirroredLocal.y * 0.45 + 0.5, 0.0, 1.0));
  col += reflectedBody * mirroredMask * 0.030 * uBodyGain;

  // The only 3D object: an aspect-correct ellipsoid with diffuse light.
  vec2 local = rotate2(p - uBodyPosition, -uTilt) / (BODY_R * uBodyScale);
  float radial2 = dot(local, local);
  float sphereD = sqrt(max(radial2, 0.0)) - 1.0;
  float sphereAA = max(fwidth(sphereD) * 1.35, 0.001);
  float sphereMask = 1.0 - smoothstep(-sphereAA, sphereAA, sphereD);

  if (sphereMask > 0.0) {
    float nz = sqrt(max(0.0, 1.0 - radial2));
    vec3 normal = normalize(vec3(local.x, local.y, nz));
    vec3 lightDirection = normalize(vec3(0.52, 0.72, 0.82));
    float diffuse = 0.62 + 0.38 * max(0.0, dot(normal, lightDirection));
    float vertical = smoothstep(-0.85, 0.90, local.y);
    vec3 body = mix(BODY_BOTTOM, BODY_TOP, vertical) * diffuse;
    // A coloured edge lift separates the blue ball from black without adding
    // the rejected white/specular candy highlight.
    body += mix(BODY_BOTTOM, BODY_TOP, 0.55) * pow(1.0 - nz, 3.2) * 0.10;
    body *= uBodyGain;

    // Spherical surface coordinates make the flat graphics foreshorten as
    // they travel around the real ball. The features emit their exact state
    // colour and therefore do not inherit the body's diffuse lighting.
    float yaw = atan(local.x, max(0.0001, nz));
    float pitch = asin(clamp(local.y, -1.0, 1.0));
    float faceYaw = uFaceDirection.x;
    float facePitch = uFaceDirection.y;
    float eyeSeparation = 0.270;
    float eyeHalfWidth = 0.085;
    float eyeHalfHeight = 0.165 * uEyeHeight;
    float leftHeight = eyeHalfHeight * (1.0 + uEyeAsymmetry * 0.20);
    float rightHeight = eyeHalfHeight * (1.0 - uEyeAsymmetry * 0.20);

    float eyeL = 0.0;
    float eyeR = 0.0;
    float glow = 0.0;
    for (int i = 0; i < 2; i++) {
      float side = i == 0 ? -1.0 : 1.0;
      float halfHeight = i == 0 ? leftHeight : rightHeight;
      vec2 ep = vec2((yaw - (faceYaw + side * eyeSeparation)) * cos(pitch),
                     pitch - facePitch);
      float eyeD = roundedBox(ep, vec2(eyeHalfWidth, halfHeight), eyeHalfWidth);
      float aa = max(fwidth(eyeD) * 1.5, 0.0015);
      float mask = 1.0 - smoothstep(-aa, aa, eyeD);
      if (i == 0) eyeL = mask; else eyeR = mask;
      glow += exp(-max(0.0, eyeD) * 30.0) * (1.0 - mask);
    }
    float eyeMask = max(eyeL, eyeR);
    vec3 eyeColour = mix(uEyeColour, READY_GREEN, uReadyFlash);
    body += eyeColour * glow * 0.10 * uEyeGain;
    body = mix(body, eyeColour * uEyeGain, eyeMask);

    // The mouth exists only while authorised voice output is present. A
    // silent state never draws a resting smile or opening.
    vec2 mouth = vec2((yaw - faceYaw) * cos(pitch),
                      pitch - (facePitch - 0.275));
    float halfMouth = 0.225;
    float mouthU = clamp(mouth.x / halfMouth, -1.0, 1.0);
    float smileCurve = uSmile * (mouthU * mouthU - 0.38) * 0.060;
    vec2 shapedMouth = vec2(mouth.x, mouth.y - smileCurve);
    vec2 openingRadius = vec2(0.135 + uMouthOpen * 0.075,
                              0.024 + uMouthOpen * 0.130);
    float openD = ellipse(shapedMouth, openingRadius);
    float openAA = max(fwidth(openD), 0.002);
    float openMask = 1.0 - smoothstep(-openAA, openAA, openD);
    float mouthMask = openMask * smoothstep(0.01, 0.08, uMouthOpen);
    body = mix(body, INK, mouthMask);

    col = mix(col, body, sphereMask);
  }

  // Existing gaze telemetry contract: barely-there when a face is detected,
  // unmistakable when that person is looking. It is evidence, not expression.
  float strip = 1.0 - smoothstep(0.0, 0.022, uv.y);
  col += vec3(0.006, 0.18, 0.035) * strip
    * min(1.0, 0.08 * uSeen + 0.48 * uLooking);

  col = col / (1.0 + col * 0.16);
  outColor = vec4(max(col, 0.0), 1.0);
}`;

export class MarshmallowRenderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly program: WebGLProgram;
  private readonly uniforms: Record<string, WebGLUniformLocation | null> = {};

  constructor(canvas: HTMLCanvasElement) {
    const gl = canvas.getContext("webgl2", { antialias: true, alpha: false });
    if (!gl) throw new Error("WebGL2 unavailable");
    this.gl = gl;
    this.program = this.link(VERT, FRAG);
    for (const name of [
      "uResolution", "uOrigin", "uTime", "uBodyPosition", "uBodyScale", "uTilt",
      "uFaceDirection", "uEyeHeight", "uEyeAsymmetry", "uEyeColour", "uEyeGain",
      "uSmile", "uMouthOpen", "uBodyGain", "uReadyFlash", "uSeen", "uLooking",
    ]) {
      this.uniforms[name] = gl.getUniformLocation(this.program, name);
    }
  }

  private link(vertexSource: string, fragmentSource: string): WebGLProgram {
    const gl = this.gl;
    const compile = (type: number, source: string) => {
      const shader = gl.createShader(type);
      if (!shader) throw new Error("shader allocation failed");
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw new Error(gl.getShaderInfoLog(shader) ?? "shader compilation failed");
      }
      return shader;
    };
    const program = gl.createProgram();
    if (!program) throw new Error("program allocation failed");
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) ?? "shader link failed");
    }
    return program;
  }

  render(
    u: MarshmallowUniforms,
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
    gl.uniform1f(this.uniforms.uTime, u.time);
    gl.uniform2f(this.uniforms.uBodyPosition, u.bodyX, u.bodyY);
    gl.uniform2f(this.uniforms.uBodyScale, u.scaleX, u.scaleY);
    gl.uniform1f(this.uniforms.uTilt, u.tilt);
    gl.uniform2f(this.uniforms.uFaceDirection, u.faceYaw, u.facePitch);
    gl.uniform1f(this.uniforms.uEyeHeight, u.eyeHeight);
    gl.uniform1f(this.uniforms.uEyeAsymmetry, u.eyeAsymmetry);
    gl.uniform3f(
      this.uniforms.uEyeColour,
      u.eyeColour[0], u.eyeColour[1], u.eyeColour[2],
    );
    gl.uniform1f(this.uniforms.uEyeGain, u.eyeGain);
    gl.uniform1f(this.uniforms.uSmile, u.smile);
    gl.uniform1f(this.uniforms.uMouthOpen, u.mouthOpen);
    gl.uniform1f(this.uniforms.uBodyGain, u.bodyGain);
    gl.uniform1f(this.uniforms.uReadyFlash, Math.min(1, Math.max(0, readyFlash)));
    gl.uniform1f(this.uniforms.uSeen, u.seen);
    gl.uniform1f(this.uniforms.uLooking, u.looking);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  dispose(): void {
    this.gl.deleteProgram(this.program);
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }
}
