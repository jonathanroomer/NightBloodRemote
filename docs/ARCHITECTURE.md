# Architecture

NightBlood Remote is a native iPhone controller wrapped around a bundled,
media-only WebGL face. The native layer owns identity, account state, task
selection and every network request. JavaScript owns rendering, microphone
capture and WebRTC playback, but receives no credential or host identity.

## Component map

```text
                         iPhone
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI                                                      │
│  settings · Face ID gate · lifecycle · Live Activity         │
│       │                                                      │
│       ├── Keychain: OAuth and controller records             │
│       ├── Secure Enclave: non-exportable P-256 private key   │
│       ├── TrueDepth: local, bounded gaze values               │
│       └── native controller transport                         │
│              │ TLS/WSS                                       │
│              ▼                                               │
│       configured remote service ─────── paired Codex host    │
│              │                                               │
│              │ SDP answer and bounded state only             │
│              ▼                                               │
│  non-persistent WKWebView                                    │
│  WebGL face · microphone · WebRTC audio · amplitude          │
└──────────────────────────────────────────────────────────────┘
```

The private relay path shown above is experimental reference code. A public
Codex App Server transport is a possible replacement, but is not implemented
in this snapshot.

## Native application

The XcodeGen manifest at `ios/NightBloodRemote/project.yml` is the source of
truth for the signed targets. Its source list is deliberately explicit: adding
a Swift file to the directory does not silently add that file to the app.

Important native components are:

- `DirectNightBloodRemoteApp.swift`: application composition.
- `DirectCompanionView.swift`: main portrait experience.
- `DirectSettingsView.swift`: sign-in, enrolment, host selection, character,
  voice and task-reference settings.
- `DeviceAccessGate.swift`: Face ID protection for a foreground controller
  session.
- `DirectVoiceSessionModel.swift`: one voice-session lifecycle and the
  one-use permission allowing the WebView to submit an SDP offer.
- `CodexPlanOAuth.swift`: experimental PKCE sign-in, with a developer-supplied
  client ID.
- `CodexRemoteEnrolment*.swift`: device identity, DeviceCheck and controller
  enrolment.
- `CodexRemoteController*.swift`: pairing, exact host selection, session-token
  refresh and WSS setup.
- `CodexRemoteVoice*.swift`: bounded App Server and realtime protocol bridge.
- `FrontCameraGazeTracker.swift`: converts face tracking into small local gaze
  values. Camera frames do not cross into JavaScript.

The Live Activity extension contains state and local controls only. It does
not receive transcript text or account credentials.

## Face and media bundle

`app/ui` is built by Vite and then inlined into one signed HTML resource. The
app loads it from its bundle into a non-persistent `WKWebView`; navigation away
from that exact file is blocked.

The face layer consumes a canonical state model. It does not decide whether a
task is working, complete, degraded or awaiting approval. NightBlood and
Marshmallow render the same truth through different visual grammars:

- `types.ts` and `resolveVisualState.ts`: canonical state contract;
- `stateParams.ts` and `faceDirector.ts`: NightBlood expression targets;
- `marshmallowStateParams.ts` and `marshmallowDirector.ts`: Marshmallow
  expression targets;
- `webglFace.ts` and `webglMarshmallow.ts`: shipping renderers;
- `FaceSurface.tsx`: explicit face selection.

The WebView may ask native Swift to start or stop the one authorised media
session. Swift validates the message origin, exact keys and bounded SDP size.
It returns only the SDP answer and a start result. OAuth tokens, controller
tokens, environment IDs, task IDs and arbitrary method names remain native.

## Blender and runtime relationship

The Blender source is a reproducible look-development kit, not a runtime
dependency. The scripts construct the stage, eyes, materials, motion loops and
state studies from code. Their accepted measurements and behaviours are then
translated manually into the WebGL state tables and shader implementation.

No `.blend` file or rendered sequence is required to build the iOS app. This
keeps the public source small, reproducible and free of workstation metadata.
See [Face creation](FACE_CREATION.md) for the complete workflow.

## State and data lifetimes

| Value | Owner | Lifetime |
|---|---|---|
| OAuth token set | native Keychain | device-only, while retained |
| Controller enrolment and selected host | native Keychain | device-only, while retained |
| Secure Enclave private key | Secure Enclave/Keychain | non-exportable |
| Controller session token | native memory | one short-lived connection |
| Task reference and face preferences | native user defaults | until locally changed/cleared |
| Camera frames | native tracking pipeline | current frame only |
| Gaze sample | native and bundled face | current bounded sample |
| Audio | WebRTC media path | active session; not recorded by this app |
| Transcript display | native memory | up to 100 items in the active process |
| Face state | bundled page | current session |

## Design constraints worth preserving

1. Do not place credentials, task identity or host identity in JavaScript.
2. Do not add raw shell or arbitrary App Server passthrough.
3. Require explicit selection of the exact paired host; never choose the only
   result automatically.
4. Do not retry a mutation whose outcome may already have occurred.
5. Treat stale or missing state as uncertainty, not idle or success.
6. Keep camera processing local and permission text honest.
7. Re-audit the signed target whenever the source allowlist, transport,
   logging, analytics or persistence changes.
