import type { FaceSkin } from "./components/face/faceSkin";
import type { DirectRealtimeStartupCue } from "./directRealtime";

/**
 * Small procedural chimes replace the private prototype's sampled sound
 * library. They are generated in memory, contain no recorded voice, and may
 * be freely changed or removed by downstream projects.
 */
function proceduralCue(
  name: string,
  frequencies: readonly number[],
): DirectRealtimeStartupCue {
  const sampleRate = 16_000;
  const durationSeconds = 0.22;
  const sampleCount = Math.floor(sampleRate * durationSeconds);
  const bytes = new Uint8Array(44 + sampleCount * 2);
  const view = new DataView(bytes.buffer);

  const writeAscii = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index += 1) {
      bytes[offset + index] = value.charCodeAt(index);
    }
  };

  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + sampleCount * 2, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, "data");
  view.setUint32(40, sampleCount * 2, true);

  for (let index = 0; index < sampleCount; index += 1) {
    const time = index / sampleRate;
    const progress = index / Math.max(1, sampleCount - 1);
    const attack = Math.min(1, progress / 0.08);
    const release = Math.min(1, (1 - progress) / 0.35);
    const envelope = attack * release * 0.22;
    const sample = frequencies.reduce(
      (total, frequency, voiceIndex) => total
        + Math.sin(2 * Math.PI * frequency * time + voiceIndex * 0.35),
      0,
    ) / frequencies.length;
    view.setInt16(44 + index * 2, Math.round(sample * envelope * 32_767), true);
  }

  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return { name, dataUrl: `data:audio/wav;base64,${window.btoa(binary)}` };
}

const CUES: Record<FaceSkin, readonly DirectRealtimeStartupCue[]> = {
  nightblood: [
    proceduralCue("nightblood/low-chime", [196, 293.66]),
    proceduralCue("nightblood/fifth", [220, 329.63]),
  ],
  marshmallow: [
    proceduralCue("marshmallow/high-chime", [523.25, 659.25]),
    proceduralCue("marshmallow/major-third", [587.33, 739.99]),
  ],
};

export function randomStartupCue(skin: FaceSkin): DirectRealtimeStartupCue {
  const cues = CUES[skin];
  return cues[Math.floor(Math.random() * cues.length)];
}
