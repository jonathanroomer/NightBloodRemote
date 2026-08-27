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

The repository deliberately ships with `CODEX_OAUTH_CLIENT_ID` and
`CODEX_PROJECT_ID` empty. The face demo remains usable; account connection does
not.

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
3. If you want the bounded voice tool to create another task in one saved
   Codex project, add that account-specific ID as `CODEX_PROJECT_ID`. Leave it
   blank to disable project listing and task creation from Voice.
4. Rebuild and inspect the generated `Info.plist` in the local product. Never
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
   or task UUID to control. The public build begins with this field empty.
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

### Network destinations

| Destination | Purpose | Data class |
|---|---|---|
| `https://auth.openai.com/oauth/authorize` | browser authorisation and step-up | PKCE/state, requested scopes |
| `https://auth.openai.com/oauth/token` | code exchange and refresh | OAuth grant data, native only |
| `https://chatgpt.com/backend-api/` | experimental enrolment, pairing, environment and refresh requests | account/controller proofs and metadata |
| `wss://chatgpt.com/backend-api/codex/remote/control/client` | experimental controller relay | bounded App Server and realtime messages |
| iOS DeviceCheck service | Apple device attestation | Apple-generated device token |
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
| Task and saved-project IDs | local settings/build configuration | repository defaults or diagnostics |
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
The realtime media portion should follow OpenAI's [WebRTC guidance](https://developers.openai.com/api/docs/guides/realtime-webrtc)
and keep long-lived credentials on a trusted native or server-side component.

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
