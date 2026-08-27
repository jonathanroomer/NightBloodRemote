import React, { useEffect, useMemo, useRef, useState } from "react";
import ReactDOM from "react-dom/client";

import { FaceSurface } from "./components/face/FaceSurface";
import { parseFaceSkin, type FaceSkin } from "./components/face/faceSkin";
import type { Watched } from "./components/face/faceDirector";
import { resolveVisualState } from "./components/face/resolveVisualState";
import type { ConnectionState, InteractionState } from "./components/face/types";
import {
  DirectRealtimeVoice,
  type DirectRealtimeStartReply,
} from "./directRealtime";
import { randomStartupCue } from "./startupCues";
import "./ios.css";

type NativeEvent = Record<string, unknown> & { type: string };

interface NightBloodDirectBridge {
  setAvailable(available: boolean): void;
  setWorking(active: boolean): void;
  setInputMuted(muted: unknown): boolean;
  setOutputMuted(muted: unknown): boolean;
  resumeAfterBackground(state: unknown): Promise<boolean>;
  setSkin(candidate: unknown): FaceSkin | null;
  start(candidate: unknown): Promise<void>;
  stop(): Promise<void>;
  closeLocalOnly(): Promise<void>;
  gaze(sample: Watched): void;
}

declare global {
  interface Window {
    NightBloodDirect?: NightBloodDirectBridge;
    webkit?: {
      messageHandlers?: {
        nightbloodDirect?: {
          postMessage(message: Record<string, unknown>): Promise<unknown>;
        };
        nightbloodEvents?: {
          postMessage(message: NativeEvent): void;
        };
      };
    };
  }
}

function postEvent(message: NativeEvent) {
  window.webkit?.messageHandlers?.nightbloodEvents?.postMessage(message);
}

async function callNative(
  operation: "start" | "stop",
  payload: Record<string, unknown> = {},
): Promise<unknown> {
  const handler = window.webkit?.messageHandlers?.nightbloodDirect;
  if (!handler) throw new Error("The signed NightBlood controller is unavailable.");
  return handler.postMessage({ operation, ...payload });
}

function requireStartReply(value: unknown): DirectRealtimeStartReply {
  if (!value || typeof value !== "object") throw new Error("Codex returned no voice answer.");
  const reply = value as Record<string, unknown>;
  if (typeof reply.sdp !== "string" || reply.serverStarted !== true) {
    throw new Error(typeof reply.error === "string" ? reply.error : "Codex rejected voice start.");
  }
  return { sdp: reply.sdp, serverStarted: true };
}

function FaceApp() {
  const [faceSkin, setFaceSkin] = useState<FaceSkin>("nightblood");
  const faceSkinRef = useRef<FaceSkin>("nightblood");
  const [connection, setConnection] = useState<ConnectionState>("offline");
  const [interaction, setInteraction] = useState<InteractionState>("idle");
  const [errorTransient, setErrorTransient] = useState(false);
  const [nowMs, setNowMs] = useState(() => performance.now());
  const [readyFlashStartedAtMs, setReadyFlashStartedAtMs] = useState<number | null>(null);
  const levelRef = useRef(0);
  const watchedRef = useRef<Watched | null>(null);
  const backingWorkRef = useRef(false);
  const awaitingAssistantRef = useRef(false);
  const userSpeakingRef = useRef(false);
  const assistantSpeakingRef = useRef(false);
  const [backingWorkActive, setBackingWorkActive] = useState(false);

  const resolved = useMemo(() => resolveVisualState({
    connection: errorTransient ? "connected" : connection,
    interaction: errorTransient ? "idle" : interaction,
    work: { activeTaskCount: backingWorkActive ? 1 : 0 },
    approval: { pendingCount: 0 },
    degradation: { degraded: false, eventGap: false, reasons: [] },
    transient: errorTransient
      ? { kind: "error", startedAtMs: nowMs, durationMs: 2_000 }
      : null,
    nowMs,
  }), [backingWorkActive, connection, errorTransient, interaction, nowMs]);

  useEffect(() => {
    const timer = window.setInterval(() => setNowMs(performance.now()), 250);
    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    const syncInteraction = () => {
      if (userSpeakingRef.current) {
        setInteraction("listening");
      } else if (assistantSpeakingRef.current) {
        setInteraction("speaking");
      } else if (awaitingAssistantRef.current || backingWorkRef.current) {
        setInteraction("thinking");
      } else {
        setInteraction("listening");
      }
    };

    const resetTurnActivity = () => {
      awaitingAssistantRef.current = false;
      userSpeakingRef.current = false;
      assistantSpeakingRef.current = false;
      backingWorkRef.current = false;
      setBackingWorkActive(false);
    };

    const realtime = new DirectRealtimeVoice({
      onState: (state, detail) => {
        if (state === "starting") {
          resetTurnActivity();
          setConnection("starting");
          setInteraction("idle");
        } else if (state === "live") {
          setConnection("connected");
          syncInteraction();
        } else if (state === "idle") {
          resetTurnActivity();
          setInteraction("idle");
        } else {
          resetTurnActivity();
          setConnection("connected");
          setInteraction("idle");
          setErrorTransient(true);
          window.setTimeout(() => setErrorTransient(false), 2_000);
        }
        postEvent({ type: "session", state, detail: detail ?? "" });
      },
      onTranscript: (role, text, done) => {
        postEvent({ type: "transcript", role, text, done });
      },
      onAmplitude: (level) => {
        levelRef.current = level;
      },
      onEvent: (kind, detail = {}) => {
        if (kind === "session-ready") {
          setReadyFlashStartedAtMs(performance.now());
        } else if (kind === "speech-started") {
          userSpeakingRef.current = true;
          assistantSpeakingRef.current = false;
          awaitingAssistantRef.current = false;
          syncInteraction();
        } else if (kind === "speech-stopped") {
          userSpeakingRef.current = false;
          awaitingAssistantRef.current = true;
          syncInteraction();
        } else if (kind === "delegation-started") {
          awaitingAssistantRef.current = true;
          syncInteraction();
        } else if (kind === "assistant-speaking") {
          userSpeakingRef.current = false;
          assistantSpeakingRef.current = true;
          awaitingAssistantRef.current = false;
          syncInteraction();
        } else if (kind === "assistant-done") {
          assistantSpeakingRef.current = false;
          awaitingAssistantRef.current = false;
          syncInteraction();
        }
        postEvent({ type: "event", kind, detail });
      },
    }, {
      async start(sdpOffer) {
        return requireStartReply(await callNative("start", { sdpOffer }));
      },
      async stop() {
        const reply = await callNative("stop");
        if (!reply || typeof reply !== "object" || (reply as Record<string, unknown>).stopped !== true) {
          const error = reply && typeof reply === "object"
            ? (reply as Record<string, unknown>).error
            : null;
          throw new Error(typeof error === "string" ? error : "Codex Voice stop was not confirmed.");
        }
      },
    }, {
      getStartupCue: () => randomStartupCue(faceSkinRef.current),
    });

    window.NightBloodDirect = {
      setAvailable(available) {
        setConnection(available ? "connected" : "offline");
        if (!available) {
          resetTurnActivity();
          setInteraction("idle");
        }
      },
      setWorking(active) {
        backingWorkRef.current = active;
        setBackingWorkActive(active);
        // `awaitingAssistant` already bridges App Server completion to the
        // first output-audio event. Do not re-arm it here: if audio has already
        // finished, turn completion must restore the ordinary ivory state.
        syncInteraction();
      },
      setInputMuted(muted) {
        if (typeof muted !== "boolean") return false;
        return realtime.setInputMuted(muted);
      },
      setOutputMuted(muted) {
        if (typeof muted !== "boolean") return false;
        return realtime.setOutputMuted(muted);
      },
      async resumeAfterBackground(candidate) {
        if (candidate !== "listening" && candidate !== "thinking"
          && candidate !== "speaking") return false;

        userSpeakingRef.current = false;
        assistantSpeakingRef.current = candidate === "speaking";
        awaitingAssistantRef.current = candidate === "thinking";
        setConnection("connected");
        setInteraction(candidate);
        return realtime.resumeAfterBackground();
      },
      setSkin(candidate) {
        const skin = parseFaceSkin(candidate);
        if (!skin) return null;
        faceSkinRef.current = skin;
        setFaceSkin(skin);
        return skin;
      },
      async start(candidate) {
        const skin = parseFaceSkin(candidate);
        if (!skin) throw new Error("The selected NightBlood character is invalid.");
        // The start grant is bound to this native-selected character. Apply it
        // synchronously here as well, so a rapid swipe-and-start cannot race
        // the ordinary asynchronous skin update and choose the wrong cue.
        faceSkinRef.current = skin;
        setFaceSkin(skin);
        await realtime.start();
      },
      async stop() {
        await realtime.stop();
      },
      async closeLocalOnly() {
        await realtime.closeLocalOnly();
      },
      gaze(sample) {
        if (!sample || sample.present !== true) {
          watchedRef.current = null;
          return;
        }
        const bounded = (value: unknown, fallback: number, lower: number, upper: number) =>
          typeof value === "number" && Number.isFinite(value)
            ? Math.min(upper, Math.max(lower, value))
            : fallback;
        watchedRef.current = {
          present: true,
          x: bounded(sample.x, 0, -1, 1),
          y: bounded(sample.y, 0, -1, 1),
          distance: bounded(sample.distance, 1, 0, 1),
          yaw: bounded(sample.yaw, 0, -90, 90),
          pitch: bounded(sample.pitch, 0, -90, 90),
        };
      },
    };
    postEvent({ type: "ready" });
    return () => {
      delete window.NightBloodDirect;
      void realtime.closeLocalOnly();
    };
  }, []);

  return (
    <FaceSurface
      skin={faceSkin}
      className="ios-face"
      resolved={resolved}
      authorisedAmplitude={0}
      liveAmplitude={() => levelRef.current}
      liveWatched={() => watchedRef.current}
      readyFlashStartedAtMs={readyFlashStartedAtMs}
    />
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <FaceApp />
  </React.StrictMode>,
);
