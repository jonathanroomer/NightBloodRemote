export interface DirectRealtimeCallbacks {
  onState: (state: "starting" | "live" | "idle" | "error", detail?: string) => void;
  onTranscript: (role: "user" | "assistant", text: string, done: boolean) => void;
  onAmplitude: (level: number) => void;
  onEvent: (kind: string, detail?: Record<string, unknown>) => void;
}

export interface DirectRealtimeStartReply {
  readonly sdp: string;
  readonly serverStarted: boolean;
}

export interface DirectRealtimeSignalling {
  start(sdpOffer: string): Promise<DirectRealtimeStartReply>;
  stop(): Promise<void>;
}

export interface DirectRealtimeStartupCue {
  readonly name: string;
  readonly dataUrl: string;
}

export interface DirectRealtimeOptions {
  readonly getStartupCue?: () => DirectRealtimeStartupCue | null;
}

const MIC_CONSTRAINTS: MediaStreamConstraints = {
  audio: {
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    channelCount: 1,
  },
};

async function waitForIceGathering(peer: RTCPeerConnection): Promise<void> {
  if (peer.iceGatheringState === "complete") return;
  await new Promise<void>((resolve) => {
    const timeout = window.setTimeout(done, 3_000);
    function done() {
      window.clearTimeout(timeout);
      peer.removeEventListener("icegatheringstatechange", changed);
      resolve();
    }
    function changed() {
      if (peer.iceGatheringState === "complete") done();
    }
    peer.addEventListener("icegatheringstatechange", changed);
  });
}

/**
 * The WebView owns media only. It has no URL, bearer, Mac identifier, task
 * identifier, WebSocket, fetch route, or raw App Server operation. Swift
 * accepts one bounded SDP offer and returns one bounded SDP answer. Codex may
 * echo session configuration over the WebRTC event channel; instruction text
 * is discarded during parsing and is never forwarded to native callbacks.
 */
export class DirectRealtimeVoice {
  private peer: RTCPeerConnection | null = null;
  private stream: MediaStream | null = null;
  private audio: HTMLAudioElement | null = null;
  private audioContext: AudioContext | null = null;
  private analyser: AnalyserNode | null = null;
  private amplitudeFrame: number | null = null;
  private activationTimer: number | null = null;
  private disconnectTimer: number | null = null;
  private statsTimer: number | null = null;
  private stopPromise: Promise<void> | null = null;
  private generation = 0;
  private serverStarted = false;
  private peerConnected = false;
  private realtimeSessionReady = false;
  private activated = false;
  private startupCuePlaying = false;
  private assistantSpeaking = false;
  private inputMuted = false;
  private outputMuted = false;
  private outputEnvelope = 0;
  private lastBytesSent = 0;
  private stalledReports = 0;
  private uplinkBaselinePending = false;
  private inputTranscriptParts: string[] = [];
  private transcriptDoneTimer: number | null = null;
  private finalInputTranscript: string | null = null;
  private finalAssistantTranscript: string | null = null;

  constructor(
    private readonly cb: DirectRealtimeCallbacks,
    private readonly signalling: DirectRealtimeSignalling,
    private readonly options: DirectRealtimeOptions = {},
  ) {}

  get running(): boolean {
    return this.peer !== null || this.stream !== null || this.stopPromise !== null;
  }

  /** Silences only local speaker playout; mic, events and analyser stay live. */
  setOutputMuted(muted: boolean): boolean {
    this.outputMuted = muted;
    if (this.audio) this.audio.muted = muted;
    return this.audio?.muted ?? this.outputMuted;
  }

  /** Mutes only the outbound microphone track; the live session stays open. */
  setInputMuted(muted: boolean): boolean {
    const tracks = this.stream?.getAudioTracks() ?? [];
    if (tracks.length !== 1 || tracks[0].readyState !== "live") {
      throw new Error("The live iPhone microphone is unavailable.");
    }
    this.inputMuted = muted;
    tracks[0].enabled = !muted && !this.startupCuePlaying;
    this.stalledReports = 0;
    this.uplinkBaselinePending = !this.inputMuted;
    return this.inputMuted;
  }

  /**
   * iOS may pause a WKWebView capture source while the app is backgrounded.
   * Keep the peer and authenticated Codex session, but replace only its local
   * audio track on foreground so a stale capture source cannot strand the next
   * user turn. No renegotiation or new remote mutation is required.
   */
  async resumeAfterBackground(): Promise<boolean> {
    const peer = this.peer;
    const previousStream = this.stream;
    if (!peer || !previousStream || !this.activated
      || peer.connectionState !== "connected") return false;

    const previousTrack = previousStream.getAudioTracks()[0];
    try {
      const replacementStream = await navigator.mediaDevices.getUserMedia(MIC_CONSTRAINTS);
      const replacementTracks = replacementStream.getAudioTracks();
      const sender = peer.getSenders().find((candidate) => candidate.track?.kind === "audio");
      if (replacementTracks.length !== 1 || !sender) {
        replacementStream.getTracks().forEach((track) => track.stop());
        return false;
      }

      replacementTracks[0].enabled = !this.inputMuted;
      await sender.replaceTrack(replacementTracks[0]);
      if (peer !== this.peer) {
        replacementStream.getTracks().forEach((track) => track.stop());
        return false;
      }
      previousStream.getTracks().forEach((track) => track.stop());
      this.stream = replacementStream;
      this.stalledReports = 0;
      this.lastBytesSent = 0;
      this.uplinkBaselinePending = !this.inputMuted;
      if (this.audioContext) void this.audioContext.resume();
      if (this.audio && !this.outputMuted) void this.audio.play().catch(() => undefined);
      this.cb.onEvent("background-media-resumed", {
        previousState: previousTrack?.readyState ?? "missing",
        previousMuted: previousTrack?.muted ?? true,
      });
      return true;
    } catch (error) {
      this.cb.onEvent("background-media-resume-failed", {
        detail: DirectRealtimeVoice.errorText(error),
      });
      return false;
    }
  }

  async start(): Promise<void> {
    if (this.stopPromise) await this.stopPromise;
    if (this.running) return;
    // Every new conversation starts audible even if a stale local mute call
    // completed after the previous session began tearing down.
    this.inputMuted = false;
    this.outputMuted = false;
    this.uplinkBaselinePending = false;
    const generation = ++this.generation;
    this.cb.onState("starting");
    try {
      await this.connect(generation);
    } catch (error) {
      if (generation === this.generation) {
        await this.closeLocal(false);
        this.cb.onState("error", DirectRealtimeVoice.errorText(error));
      }
      throw error;
    }
  }

  async stop(): Promise<void> {
    const active = this.stopPromise;
    if (active) return active;
    const task = this.performStop();
    this.stopPromise = task;
    try {
      await task;
    } finally {
      if (this.stopPromise === task) this.stopPromise = null;
    }
  }

  /** Native background handling closes Remote independently, then calls this. */
  async closeLocalOnly(): Promise<void> {
    ++this.generation;
    await this.closeLocal(false);
    this.cb.onState("idle");
  }

  private async connect(generation: number): Promise<void> {
    const stream = await navigator.mediaDevices.getUserMedia(MIC_CONSTRAINTS);
    if (generation !== this.generation) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }
    const audioTracks = stream.getAudioTracks();
    if (audioTracks.length !== 1) {
      stream.getTracks().forEach((track) => track.stop());
      throw new Error("The iPhone microphone did not provide one audio track.");
    }
    this.stream = stream;
    audioTracks[0].enabled = !this.inputMuted;
    this.cb.onEvent("microphone-ready", {
      enabled: audioTracks[0].enabled,
      muted: audioTracks[0].muted,
    });

    const peer = new RTCPeerConnection();
    this.peer = peer;
    peer.ontrack = (event) => {
      if (peer !== this.peer || generation !== this.generation) return;
      const [remote] = event.streams;
      if (remote) this.attachOutput(remote);
    };
    peer.onconnectionstatechange = () => {
      if (peer !== this.peer || generation !== this.generation) return;
      this.cb.onEvent("peer-state", { state: peer.connectionState });
      if (peer.connectionState === "connected") {
        this.peerConnected = true;
        if (this.disconnectTimer !== null) {
          window.clearTimeout(this.disconnectTimer);
          this.disconnectTimer = null;
        }
        this.tryActivate(generation);
      } else if (peer.connectionState === "failed") {
        this.fail(peer, "The Codex Voice media connection failed.");
      } else if (peer.connectionState === "disconnected" && this.disconnectTimer === null) {
        this.disconnectTimer = window.setTimeout(() => {
          this.disconnectTimer = null;
          if (peer.connectionState === "disconnected") {
            this.fail(peer, "The Codex Voice media connection was lost.");
          }
        }, 2_500);
      }
    };

    const events = peer.createDataChannel("oai-events");
    events.onmessage = (message) => {
      if (peer === this.peer && generation === this.generation) {
        this.onRealtimeEvent(message.data);
      }
    };
    events.onopen = () => this.cb.onEvent("data-channel-open");
    events.onclose = () => {
      if (peer.connectionState !== "closed") {
        this.fail(peer, "The Codex Voice event channel closed.");
      }
    };
    events.onerror = () => this.fail(peer, "The Codex Voice event channel failed.");

    for (const track of stream.getTracks()) peer.addTrack(track, stream);
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await waitForIceGathering(peer);
    if (peer !== this.peer || generation !== this.generation) return;
    const sdpOffer = peer.localDescription?.sdp ?? offer.sdp;
    if (typeof sdpOffer !== "string" || !sdpOffer.startsWith("v=0")
      || new TextEncoder().encode(sdpOffer).byteLength > 128 * 1024) {
      throw new Error("The iPhone produced an invalid WebRTC offer.");
    }

    const reply = await this.signalling.start(sdpOffer);
    if (peer !== this.peer || generation !== this.generation) return;
    if (reply.serverStarted !== true || !reply.sdp.startsWith("v=0")
      || new TextEncoder().encode(reply.sdp).byteLength > 128 * 1024) {
      throw new Error("Codex did not return a valid confirmed WebRTC answer.");
    }
    this.serverStarted = true;
    await peer.setRemoteDescription({ type: "answer", sdp: reply.sdp });
    if (peer !== this.peer || generation !== this.generation) return;
    this.activationTimer = window.setTimeout(() => {
      this.activationTimer = null;
      if (!this.activated && peer === this.peer) {
        this.fail(peer, "Codex Voice did not finish connecting.");
      }
    }, 15_000);
    this.tryActivate(generation);
  }

  private tryActivate(generation: number) {
    if (generation !== this.generation || this.activated) return;
    if (!this.serverStarted || !this.peerConnected || !this.realtimeSessionReady
      || !this.audioContext) return;
    this.activated = true;
    if (this.activationTimer !== null) window.clearTimeout(this.activationTimer);
    this.activationTimer = null;
    void this.finishActivation(generation);
  }

  private async finishActivation(generation: number): Promise<void> {
    const track = this.stream?.getAudioTracks()[0];
    this.startupCuePlaying = true;
    if (track?.readyState === "live") track.enabled = false;

    // Play the character cue inside WebKit's already-established voice audio
    // graph. Taking ownership of AVAudioSession natively before getUserMedia
    // can starve WebRTC's outbound microphone on a physical iPhone. Gating the
    // outbound track also prevents the spoken cue becoming the user's first
    // turn through acoustic echo.
    try {
      await this.playCharacterStartupCue();
    } catch (error) {
      // A cue must never strand an otherwise healthy Codex voice session.
      this.cb.onEvent("startup-cue-skipped", {
        detail: DirectRealtimeVoice.errorText(error),
      });
    }
    if (generation !== this.generation || !this.activated) return;

    this.startupCuePlaying = false;
    const currentTrack = this.stream?.getAudioTracks()[0];
    if (currentTrack?.readyState === "live") {
      currentTrack.enabled = !this.inputMuted;
      this.uplinkBaselinePending = !this.inputMuted;
    }
    this.cb.onEvent("session-ready");
    this.cb.onState("live");
    this.watchUplink(generation);
  }

  private async playCharacterStartupCue(): Promise<void> {
    const context = this.audioContext;
    const cue = this.options.getStartupCue?.();
    if (!context || !cue) {
      await this.playListeningReadyCue();
      return;
    }

    try {
      await context.resume();
      const audio = await context.decodeAudioData(DirectRealtimeVoice.decodeDataUrl(cue.dataUrl));
      if (context !== this.audioContext || context.state === "closed") return;
      await new Promise<void>((resolve) => {
        const source = context.createBufferSource();
        const gain = context.createGain();
        let finished = false;
        const timeout = window.setTimeout(finish, Math.max(1_000, (audio.duration + 0.5) * 1_000));
        function finish() {
          if (finished) return;
          finished = true;
          window.clearTimeout(timeout);
          source.disconnect();
          gain.disconnect();
          resolve();
        }
        source.buffer = audio;
        gain.gain.value = 0.72;
        source.connect(gain);
        gain.connect(context.destination);
        source.onended = finish;
        source.start();
      });
      this.cb.onEvent("startup-cue-played", { name: cue.name });
    } catch (error) {
      this.cb.onEvent("startup-cue-fallback", {
        name: cue.name,
        detail: DirectRealtimeVoice.errorText(error),
      });
      await this.playListeningReadyCue();
    }
  }

  private async playListeningReadyCue(): Promise<void> {
    const context = this.audioContext;
    if (!context) return;

    const notes = [
      { frequency: 659.25, offset: 0, duration: 0.075, gain: 0.11 },
      { frequency: 987.77, offset: 0.1, duration: 0.105, gain: 0.13 },
    ];
    const start = context.currentTime + 0.012;
    await context.resume();
    await new Promise<void>((resolve) => {
      let remaining = notes.length;
      for (const note of notes) {
        const oscillator = context.createOscillator();
        const envelope = context.createGain();
        const noteStart = start + note.offset;
        const noteEnd = noteStart + note.duration;

        oscillator.type = "sine";
        oscillator.frequency.setValueAtTime(note.frequency, noteStart);
        envelope.gain.setValueAtTime(0.0001, noteStart);
        envelope.gain.exponentialRampToValueAtTime(note.gain, noteStart + 0.012);
        envelope.gain.setValueAtTime(note.gain, Math.max(noteStart + 0.012, noteEnd - 0.014));
        envelope.gain.exponentialRampToValueAtTime(0.0001, noteEnd);
        oscillator.connect(envelope);
        envelope.connect(context.destination);
        oscillator.onended = () => {
          oscillator.disconnect();
          envelope.disconnect();
          remaining -= 1;
          if (remaining === 0) resolve();
        };
        oscillator.start(noteStart);
        oscillator.stop(noteEnd + 0.005);
      }
    });
  }

  private attachOutput(remote: MediaStream) {
    const audio = new Audio();
    audio.srcObject = remote;
    audio.autoplay = true;
    audio.muted = this.outputMuted;
    audio.setAttribute("playsinline", "");
    audio.setAttribute("aria-hidden", "true");
    audio.style.display = "none";
    document.body.appendChild(audio);
    this.audio = audio;
    void audio.play().catch((error) => {
      if (this.audio === audio && this.peer) {
        this.fail(this.peer, `The iPhone speaker could not start: ${DirectRealtimeVoice.errorText(error)}`);
      }
    });

    const context = new AudioContext();
    const source = context.createMediaStreamSource(remote);
    const analyser = context.createAnalyser();
    analyser.fftSize = 512;
    source.connect(analyser);
    this.audioContext = context;
    this.analyser = analyser;
    void context.resume();
    this.tryActivate(this.generation);

    const samples = new Uint8Array(analyser.frequencyBinCount);
    const tick = () => {
      if (this.analyser !== analyser) return;
      analyser.getByteTimeDomainData(samples);
      let sum = 0;
      for (const sample of samples) {
        const centred = (sample - 128) / 128;
        sum += centred * centred;
      }
      const rms = Math.sqrt(sum / samples.length);
      const gated = rms <= 0.018 ? 0 : Math.min(1, (rms - 0.018) / 0.12);
      this.outputEnvelope = gated > this.outputEnvelope ? gated : this.outputEnvelope * 0.82;
      if (this.outputEnvelope < 0.002) this.outputEnvelope = 0;
      this.cb.onAmplitude(this.outputEnvelope);
      this.amplitudeFrame = window.requestAnimationFrame(tick);
    };
    this.amplitudeFrame = window.requestAnimationFrame(tick);
  }

  private onRealtimeEvent(raw: unknown) {
    if (typeof raw !== "string" || raw.length > 512 * 1024) return;
    let event: {
      type?: string;
      transcript?: string;
      delta?: string;
      item?: { text?: string };
      turn?: { role?: string; transcript?: string };
      session?: { id?: string };
      sessionId?: string;
      session_id?: string;
    };
    try {
      event = JSON.parse(raw, (key, value: unknown) => {
        if (key === "instructions" || key === "prompt"
          || key === "realtimeStartInstructions") return undefined;
        return value;
      });
    } catch {
      return;
    }
    const type = event.type ?? "";
    if (type === "session.started" || type === "session.updated") {
      const id = event.session?.id ?? event.sessionId ?? event.session_id;
      if (typeof id === "string" && id.length > 0) {
        this.realtimeSessionReady = true;
        this.tryActivate(this.generation);
      }
    }
    if (type === "input_audio_buffer.speech_started") {
      this.assistantSpeaking = false;
      this.finalInputTranscript = null;
      this.finalAssistantTranscript = null;
      this.cb.onEvent("speech-started");
    }
    if (type === "input_audio_buffer.speech_stopped") this.cb.onEvent("speech-stopped");
    // These are the two bounded handoff markers used by current Codex Voice.
    // They contain no task result or credential; they simply let the face
    // acknowledge immediately that the backing Codex turn is beginning. The
    // native App Server turn notifications remain authoritative for when the
    // violet working state ends.
    if (type === "conversation.handoff.requested" || type === "delegation.created") {
      this.cb.onEvent("delegation-started");
    }
    if (type.endsWith("input_audio_transcription.completed") && event.transcript) {
      this.finishInputTranscript(event.transcript);
    }
    if (type === "input_transcript.added" && event.item?.text) {
      const current = this.mergeTranscriptPart(event.item.text);
      this.cb.onTranscript("user", current, false);
      this.scheduleInputTranscriptDone();
    }
    if (type === "response.audio_transcript.delta" && event.delta) {
      this.beginAssistantSpeaking();
      this.cb.onTranscript("assistant", event.delta, false);
    }
    if (type === "response.audio_transcript.done" && event.transcript) {
      this.finishAssistant(event.transcript);
    }
    if (type === "output_transcript.added" && event.item?.text) {
      this.beginAssistantSpeaking();
      this.cb.onTranscript("assistant", event.item.text, false);
    }
    if (type === "turn.done" && event.turn?.role === "assistant") {
      this.finishAssistant(event.turn.transcript ?? "");
    }
  }

  private mergeTranscriptPart(part: string): string {
    const words = part.match(/[A-Za-z0-9%']+/g) ?? [];
    let overlap = Math.min(this.inputTranscriptParts.length, words.length);
    while (overlap > 0) {
      const tail = this.inputTranscriptParts.slice(-overlap).map((word) => word.toLowerCase());
      const head = words.slice(0, overlap).map((word) => word.toLowerCase());
      if (tail.every((word, index) => word === head[index])) break;
      overlap -= 1;
    }
    this.inputTranscriptParts.push(...words.slice(overlap));
    const terminal = part.trim().match(/[.!?]$/)?.[0] ?? "";
    return this.inputTranscriptParts.join(" ") + terminal;
  }

  private scheduleInputTranscriptDone() {
    if (this.transcriptDoneTimer !== null) window.clearTimeout(this.transcriptDoneTimer);
    this.transcriptDoneTimer = window.setTimeout(() => {
      this.transcriptDoneTimer = null;
      this.finishInputTranscript(this.inputTranscriptParts.join(" "));
    }, 900);
  }

  private finishInputTranscript(text: string) {
    if (this.transcriptDoneTimer !== null) window.clearTimeout(this.transcriptDoneTimer);
    this.transcriptDoneTimer = null;
    this.inputTranscriptParts = [];
    const bounded = text.trim().slice(0, 16_384);
    if (!bounded || bounded === this.finalInputTranscript) return;
    this.finalInputTranscript = bounded;
    this.cb.onTranscript("user", bounded, true);
  }

  private beginAssistantSpeaking() {
    if (this.assistantSpeaking) return;
    this.assistantSpeaking = true;
    this.cb.onEvent("assistant-speaking");
  }

  private finishAssistant(text: string) {
    this.assistantSpeaking = false;
    this.cb.onEvent("assistant-done");
    const bounded = text.trim().slice(0, 16_384);
    if (!bounded || bounded === this.finalAssistantTranscript) return;
    this.finalAssistantTranscript = bounded;
    this.cb.onTranscript("assistant", bounded, true);
  }

  private watchUplink(generation: number) {
    let sampleInFlight = false;
    this.statsTimer = window.setInterval(() => {
      if (sampleInFlight) return;
      sampleInFlight = true;
      void (async () => {
        try {
          const peer = this.peer;
          if (!peer || generation !== this.generation) return;
          const stats = await peer.getStats();
          if (peer !== this.peer || generation !== this.generation) return;
          let bytesSent = 0;
          stats.forEach((report) => {
            if (report.type === "outbound-rtp" && report.kind === "audio") {
              bytesSent += (report as RTCOutboundRtpStreamStats).bytesSent ?? 0;
            }
          });
          if (this.inputMuted) {
            // A deliberately disabled audio track may stop increasing bytesSent.
            // Keep the peer alive and resume the health check after unmuting.
            this.stalledReports = 0;
            this.uplinkBaselinePending = false;
            this.lastBytesSent = bytesSent;
            return;
          }
          if (this.uplinkBaselinePending) {
            // Give a newly re-enabled audio source one sample to establish its
            // cumulative RTP baseline before treating silence as a fault.
            this.uplinkBaselinePending = false;
            this.stalledReports = 0;
            this.lastBytesSent = bytesSent;
            return;
          }
          if (bytesSent > this.lastBytesSent) {
            this.stalledReports = 0;
          } else if (++this.stalledReports === 3) {
            this.fail(peer, "The microphone is not reaching Codex.");
          }
          this.lastBytesSent = bytesSent;
        } catch {
          // Stop/background may close the peer while getStats is suspended.
          // Lifecycle and connection handlers own any real terminal failure.
        } finally {
          sampleInFlight = false;
        }
      })();
    }, 2_000);
  }

  private fail(peer: RTCPeerConnection, detail: string) {
    if (peer !== this.peer || this.stopPromise) return;
    void (async () => {
      await this.closeLocal(false);
      this.cb.onState("error", detail);
    })();
  }

  private async performStop() {
    ++this.generation;
    await this.closeLocal(false);
    try {
      await this.signalling.stop();
      this.cb.onState("idle");
    } catch (error) {
      this.cb.onState("error", DirectRealtimeVoice.errorText(error));
      throw error;
    }
  }

  private async closeLocal(incrementGeneration: boolean) {
    if (incrementGeneration) ++this.generation;
    if (this.statsTimer !== null) window.clearInterval(this.statsTimer);
    if (this.amplitudeFrame !== null) window.cancelAnimationFrame(this.amplitudeFrame);
    if (this.activationTimer !== null) window.clearTimeout(this.activationTimer);
    if (this.disconnectTimer !== null) window.clearTimeout(this.disconnectTimer);
    if (this.transcriptDoneTimer !== null) window.clearTimeout(this.transcriptDoneTimer);
    this.statsTimer = null;
    this.amplitudeFrame = null;
    this.activationTimer = null;
    this.disconnectTimer = null;
    this.transcriptDoneTimer = null;
    this.stream?.getTracks().forEach((track) => track.stop());
    this.audio?.pause();
    this.audio?.remove();
    if (this.audioContext) await this.audioContext.close().catch(() => undefined);
    if (this.peer) {
      this.peer.onconnectionstatechange = null;
      this.peer.close();
    }
    this.peer = null;
    this.stream = null;
    this.audio = null;
    this.audioContext = null;
    this.analyser = null;
    this.serverStarted = false;
    this.peerConnected = false;
    this.realtimeSessionReady = false;
    this.activated = false;
    this.startupCuePlaying = false;
    this.assistantSpeaking = false;
    this.outputEnvelope = 0;
    this.lastBytesSent = 0;
    this.stalledReports = 0;
    this.uplinkBaselinePending = false;
    this.inputTranscriptParts = [];
    this.finalInputTranscript = null;
    this.finalAssistantTranscript = null;
    this.inputMuted = false;
    this.outputMuted = false;
    this.cb.onAmplitude(0);
  }

  private static errorText(error: unknown): string {
    if (error instanceof Error) return error.message.slice(0, 512);
    return String(error).slice(0, 512);
  }

  private static decodeDataUrl(dataUrl: string): ArrayBuffer {
    const comma = dataUrl.indexOf(",");
    const header = dataUrl.slice(0, comma);
    if (comma < 0 || !header.startsWith("data:audio/") || !header.endsWith(";base64")) {
      throw new Error("The bundled startup cue is invalid.");
    }
    const binary = window.atob(dataUrl.slice(comma + 1));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes.buffer;
  }
}
