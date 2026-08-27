# Connections and setup

This document separates what anyone can build today from the experimental
connection code retained for study. Do not put an OAuth client ID, task ID,
project ID, Apple team ID, token, host name or pairing code into a commit.

## What works without a private service

| Capability | Simulator | Physical iPhone | External account needed |
|---|---:|---:|---:|
| Build, layout and both live faces | Yes | Yes | No |
| State-driven animation and procedural cues | Yes | Yes | No |
| TrueDepth gaze | No | Yes | No |
| Face ID and Secure Enclave behaviour | Not authoritative | Yes | No |
| Live Activity and background audio lifecycle | Partial | Yes | No |
| Direct Codex Remote voice | No | Experimental | Yes; not publicly registerable here |
| Public Codex App Server transport | Not implemented | Not implemented | Depends on your design |

The repository deliberately ships with `CODEX_OAUTH_CLIENT_ID` empty and both
`NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` and
`NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` set to `NO`. The face demo remains
usable; account connection and mutating Voice tools do not silently become
available.

## Build and Apple signing

For a Simulator build:

```bash
npm --prefix app/ui ci
make ios-project
make simulator-build
```

For a physical iPhone:

1. Replace both `com.example` bundle identifiers in
   `ios/NightBloodRemote/project.yml` with identifiers owned by you.
2. Run `make ios-project`.
3. Open the generated project and select your Apple development team locally.
4. Confirm the app and Live Activity extension use the intended profiles and
   contain no unexpected entitlements.
5. Build to a physical Face ID iPhone. Expect camera, Face ID and microphone
   permission prompts only when their features are used.

The generated `.xcodeproj` is ignored because Xcode can write user names,
signing teams, device destinations and absolute paths into it. Do not remove
that ignore rule merely to make setup look easier.

## Direct Codex Remote route: experimental only

The direct route mirrors a private Codex controller protocol. It is not a
documented, generally available third-party API. At the date of this public
snapshot, OpenAI's public documentation does not provide a registration flow
for a third-party iPhone controller of this kind. The relay paths, scopes,
model name, attestation rules and response formats may change or reject your
build.

Do not extract or reuse a client ID from Codex, ChatGPT or another application.
An OAuth client ID identifies the registered application; borrowing one is not
a supported configuration and can misrepresent your app to the account owner
and service.

If OpenAI has explicitly issued a registration for your application, keep the
value out of tracked source:

1. Generate the Xcode project.
2. In the local, ignored project, add the user-defined build setting
   `CODEX_OAUTH_CLIENT_ID` to the app target.
3. If you want the bounded Voice tool to create another persistent local task
   using the current task's workspace and permission context, set
   `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` to `YES` only in the ignored local
   app-target configuration. No saved-project ID is required or accepted.
4. Leave `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` as `NO` unless you deliberately
   accept Voice-created/deleted heartbeat files on the paired host. To opt in,
   set it to `YES` only in the ignored local app-target configuration.
5. Rebuild and inspect the generated `Info.plist` in the local product. Never
   upload that product as a source artefact.

The app also needs access to the experimental server-side controller feature
and a supported physical iPhone. Supplying a string in Xcode cannot grant that
access.

### Direct connection sequence

1. **Ordinary sign-in.** Native Swift creates a PKCE verifier, challenge and
   random state. It starts a loopback callback listener on port 1455 or 1457,
   opens `auth.openai.com` in `SFSafariViewController`, validates the callback
   state and exchanges the code natively.
2. **Device identity.** The app creates a P-256 signing key in the Secure
   Enclave. The private key is non-exportable; only public identity and signed
   proofs leave the phone.
3. **Fresh enrolment authority.** Native Swift requests the narrow
   `codex.remote_control.enroll` step-up scope, validates account claims and
   freshness, obtains a DeviceCheck token, and performs the start/finish
   challenge exchange.
4. **Manual pairing.** A supported Codex host must display a one-time,
   eight-character pairing code. The user enters that exact code on the phone.
   The attempt is single-use. An interrupted response is recorded as unknown,
   not automatically retried.
5. **Host selection.** The app fetches a fresh list of paired environments.
   The user explicitly selects one online host. Even a single result is never
   selected automatically. The binding is revalidated before each session.
6. **Task selection.** In Settings, the user pastes the exact Codex task link
   or task UUID to control. The app validates and stores only the canonical
   UUID, not the complete pasted link. The public build begins empty.
7. **Controller session.** Native Swift performs the refresh challenge, keeps
   the short-lived controller token in memory, and opens a TLS-protected WSS
   connection to the selected environment through the relay.
8. **App Server handshake.** The controller sends the bounded initialise
   exchange and binds all subsequent messages to the chosen account, client,
   environment and task.
9. **Voice start.** After a foreground user tap and Face ID, the WebView makes
   one microphone/WebRTC offer. Swift sends a `thread/realtime/start` request
   using the v3/WebRTC transport and the selected native character prompt,
   then returns only the SDP answer to the WebView.
10. **Session end.** Stop is one-shot. Native state, media ownership,
    background audio and the Live Activity are torn down. If a mutation's
    result cannot be confirmed, the UI reports an unknown outcome instead of
    silently retrying.

### Bounded Voice tool authority

Passing the foreground Face ID gate authorises the session as a whole. There
is no second Face ID or confirmation prompt for each enabled tool request.
Use a least-privilege source task and review its host sandbox, approval policy,
connectors and credentials before starting Voice.

NightBlood implements only these native Codex app tools:

- `list_projects` returns either no project or one fixed synthetic alias with
  the placeholder path `/nightblood/configured-project`. It never returns the
  project name, account-specific project ID or actual host path.
- `create_thread` is available only when
  `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION=YES`. It can create up to 32
  persistent local tasks per Voice session. The new task receives the model-
  generated prompt/title and inherits the source task's working directory,
  workspace roots, sandbox mode, approval policy, approval reviewer,
  permission profile and service tier on the paired host.
- `read_thread` and `wait_threads` can inspect only tasks created by that same
  Voice session. Results can include their title, status and bounded user and
  assistant message text, which is returned to the Realtime model.
- `automation_update` can create or delete only one heartbeat owned by the
  current Voice task. It is disabled unless
  `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS=YES`; when enabled, it writes or removes
  an automation directory under the paired host's Codex automation store.

There is no Voice route for raw shell commands, raw MCP/App Server calls,
approval responses, user-input requests, arbitrary filesystem access or task
archiving. The paired host and service may persist task prompts, messages and
automation configuration according to their normal retention behaviour.

### Network destinations

| Destination | Purpose | Data class |
|---|---|---|
| `https://auth.openai.com/oauth/authorize` | browser authorisation and step-up | PKCE/state, requested scopes |
| `https://auth.openai.com/oauth/token` | code exchange and refresh | OAuth grant data, native only |
| `https://chatgpt.com/backend-api/` | experimental enrolment, pairing, environment and refresh requests | account/controller proofs and metadata |
| `wss://chatgpt.com/backend-api/codex/remote/control/client` | experimental controller relay | bounded App Server and realtime messages |
| iOS DeviceCheck service | request an Apple device token | Apple receives the token request |
| experimental controller attestation exchange | enrolment proof | Apple token, bundle ID, up to 16 preferred language tags, locale, time zone, combined screen-point dimensions, screen scale, per-launch app-session UUID and token-generation latency |
| `http://127.0.0.1:1455/auth/callback` or port 1457 | same-device OAuth callback | short-lived code and state |

There is no Mac LAN listener in this target. The loopback HTTP callback stays
on the iPhone and exists only during sign-in.

### Secret and identifier handling

| Value | Where it belongs | Must never go |
|---|---|---|
| Apple team and signing identity | local Xcode/signing configuration | Git, screenshots, issue logs |
| OAuth client ID | local ignored build setting, if officially issued | tracked source or copied from another app |
| OAuth and refresh tokens | device-only native Keychain | WebView, logs, crash text, Git |
| Secure Enclave private key | Secure Enclave | export, logs, JavaScript |
| Controller/session token | native memory | disk, WebView, logs |
| Pairing code | one exact native submission | analytics, retry queues, screenshots |
| Host/environment ID | device-only native record | WebView or repository |
| Task UUID | canonical UUID in app preferences | full pasted link, WebView, repository defaults or diagnostics |
| Voice project alias | fixed non-account alias in source | do not replace it with a real saved-project ID or host path |
| SDP | bounded native/WebView bridge and realtime request | persistent storage |

## Public Codex App Server alternative

OpenAI documents Codex App Server as the supported integration surface for
rich clients. Its official documentation includes a local WebSocket example:

```bash
codex app-server --listen ws://127.0.0.1:4500
```

See the [official Codex App Server documentation](https://developers.openai.com/codex/app-server).
The documentation describes WebSocket transport as experimental and advises
secure WebSockets, authentication and TLS for non-local exposure.

NightBlood Remote does **not** currently connect to that socket. Implementing
the alternative safely requires an explicit design for device-to-host trust,
pairing, certificate validation, message bounds and the approval boundary. Do
not expose a raw, unauthenticated App Server port to Wi-Fi or the internet.
The realtime media portion should follow OpenAI's [WebRTC guidance](https://developers.openai.com/api/docs/guides/realtime-webrtc).
A standard OpenAI API key must remain on a trusted backend server—never in a
browser or distributed iOS binary. Give the client an ephemeral client secret,
or have a protected backend send the SDP offer to the Realtime API, following
the official guide. Do not treat native app storage as a safe place for a
long-lived server API key.

## Failure and recovery

- **No OAuth client ID:** expected for the public build. Use demo mode; do not
  hunt for a first-party ID.
- **Simulator enrolment failure:** expected. DeviceCheck, Secure Enclave,
  Face ID and TrueDepth must be judged on a supported physical device.
- **Callback port unavailable:** end the current sign-in and inspect which
  process owns ports 1455/1457. Do not broaden the listener to the LAN.
- **Enrolment or pairing outcome unknown:** verify server-side controller and
  environment state. Do not press the mutation again merely because the UI did
  not receive its reply.
- **Host missing/offline:** refresh the native list and select the exact
  intended host. Never substitute another host automatically.
- **Task invalid:** paste a complete task link or canonical task ID belonging
  to the selected host/account.
- **Voice task creation unavailable:** this is the safe default. Set
  `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION=YES` only in the ignored local build
  after reviewing the inherited permissions. Do not add a real project ID or
  change the source to return the real host path.
- **Voice automation unavailable:** this is the safe default. Enable
  `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` locally only after accepting its host
  filesystem mutation and retention behaviour.
- **WSS or realtime closes:** start a new user-authorised session. Do not reuse
  an expired controller token or blindly replay start/stop.
- **WebView failure:** the native session should close. Reloading the visual
  page must not inherit credentials or an unconsumed authority grant.

## Revocation and local reset

This source snapshot has no polished in-app sign-out or controller-revocation
screen. Revoke the controller from the authoritative Codex/account or host
management surface available to your approved setup, then verify that a fresh
environment lookup or session attempt no longer succeeds.

Deleting an iOS app is not adequate proof that every Keychain record has been
revoked upstream, and upstream revocation does not itself erase local records.
A distributor who enables the direct route should implement, test and document
both operations before shipping it to other people.

After suspected compromise, revoke upstream sessions/controllers, change the
account credentials if required, remove the affected host access, and rebuild
from reviewed source. Do not publish tokens, pairing codes or private logs when
asking for help.
