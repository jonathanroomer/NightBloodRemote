// One AEC-processed microphone stream. Resampling and 20 ms PCM packing run
// on the audio thread; the main thread only transfers the finished packet.
export const PCM_WORKLET_SOURCE = `
class NightBloodPcm extends AudioWorkletProcessor {
  constructor() {
    super();
    this.packet = new Int16Array(320);
    this.used = 0;
    this.weight = 0;
    this.total = 0;
    this.ratio = sampleRate / 16000;
  }
  process(inputs) {
    const input = inputs[0] && inputs[0][0];
    if (!input) return true;
    for (const value of input) {
      let remaining = 1;
      while (remaining > 1e-9) {
        const take = Math.min(remaining, this.ratio - this.weight);
        this.total += value * take;
        this.weight += take;
        remaining -= take;
        if (this.weight >= this.ratio - 1e-9) {
          const sample = Math.max(-1, Math.min(1, this.total / this.ratio));
          this.packet[this.used++] = Math.round(sample * (sample < 0 ? 32768 : 32767));
          this.weight = 0;
          this.total = 0;
          if (this.used === this.packet.length) {
            this.port.postMessage(this.packet.buffer, [this.packet.buffer]);
            this.packet = new Int16Array(320);
            this.used = 0;
          }
        }
      }
    }
    return true;
  }
}
registerProcessor('nightblood-pcm', NightBloodPcm);
`;

export function pcmBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

export async function createLocalPcmTap(
  context: AudioContext,
  onPacket: (pcm16: string, durationMs: number) => void,
): Promise<AudioWorkletNode | ScriptProcessorNode> {
  if (context.audioWorklet && typeof AudioWorkletNode !== "undefined") {
    const url = URL.createObjectURL(new Blob([PCM_WORKLET_SOURCE], { type: "text/javascript" }));
    try {
      await context.audioWorklet.addModule(url);
      const node = new AudioWorkletNode(context, "nightblood-pcm", {
        numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
      });
      node.port.onmessage = (event: MessageEvent<ArrayBuffer>) => {
        onPacket(pcmBase64(new Uint8Array(event.data)), 20);
      };
      return node;
    } catch {
      // Older signed WebKit builds retain a bounded, one-microphone fallback.
    } finally {
      URL.revokeObjectURL(url);
    }
  }
  const node = context.createScriptProcessor(1024, 1, 1);
  // Keep fractional resampling state across callbacks, including 44.1 kHz.
  const ratio = context.sampleRate / 16_000;
  let total = 0, weight = 0;
  node.onaudioprocess = (event) => {
    const input = event.inputBuffer.getChannelData(0);
    const samples: number[] = [];
    for (const value of input) {
      let remaining = 1;
      while (remaining > 1e-9) {
        const take = Math.min(remaining, ratio - weight);
        total += value * take;
        weight += take;
        remaining -= take;
        if (weight >= ratio - 1e-9) {
          const sample = Math.max(-1, Math.min(1, total / ratio));
          samples.push(Math.round(sample * (sample < 0 ? 32768 : 32767)));
          weight = 0;
          total = 0;
        }
      }
    }
    onPacket(pcmBase64(new Uint8Array(new Int16Array(samples).buffer)), samples.length / 16);
  };
  return node;
}

export function closeLocalPcmTap(node: AudioWorkletNode | ScriptProcessorNode | null) {
  if (!node) return;
  node.disconnect();
  if ("port" in node) {
    node.port.onmessage = null;
    node.port.close();
  } else {
    node.onaudioprocess = null;
  }
}
