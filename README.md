# NightBlood Remote for iPhone

NightBlood Remote was not a carefully planned or particularly well thought out
product. It started as a fun experiment: could I give the latest voice models a
face and a personality, inspired by some of the brilliant characters in my
favourite books?

On the iPhone, that means an animated WebGL face, full-duplex WebRTC audio,
local TrueDepth gaze input and a Lock Screen Live Activity. I have also included
the Blender scripts I used to work out the original face design and its
different listening, thinking, speaking and failure states.

This privacy-sanitised public source is **iOS 1.8.2, build 28**, including the
setup and recovery fixes verified on two phones and in CarPlay. It contains
no private Git history, developer-team identifier, provisioning
profile, device identifier, host name, bearer token, account identifier,
personal prompt text or sampled voice clip.

## September update

This update includes the CarPlay implementation introduced in build 23, with
clearer connection errors, a Reconnect button, desktop transcript attachment,
and smoother face rendering. The public build uses generic editable prompts,
procedural chimes and a system terminal symbol for the intro. No private voice
samples or vendor app icon are redistributed. See [release notes](docs/RELEASE_1.8.2.md).

CarPlay requires iOS 26.4 or later and Apple's approval for the Voice Based
Conversation entitlement. A simulator build does not establish that approval.

## Connect your Mac and iPhone

Start with the [step-by-step setup guide](docs/SETUP.md). It covers Apple
signing, Mac Remote settings, ChatGPT sign-in, iPhone enrolment, pairing and
selecting the Codex task. Agents should also read [AGENTS.md](AGENTS.md).

**Use the latest Codex desktop app approved for your Mac.** The working setup
was verified on desktop **26.908.70816, build 9275**. Older desktop builds can
pair successfully but fail transcript attachment with `desktop_endpoint_missing`.
Update the desktop app first; updating only the Codex CLI is not sufficient.
See [desktop compatibility](docs/SETUP.md#desktop-version-compatibility) for the
tested versions and managed-Mac guidance. Future desktop compatibility still
needs verification because this integration uses private interfaces.

Check workspace Remote Control permission, this Mac's Remote setup and the
selected task's permissions separately. Trusting the phone also does not enable
Developer Mode: turn it on, restart and confirm it before installing. The guide
and [setup lessons](docs/SETUP_LESSONS_2026-09-16.md) record the required order,
known fixes and the exact tested combinations.

**16 September setup fix:** earlier public builds stopped at sign-in because
`CODEX_OAUTH_CLIENT_ID` was blank. The build now includes the public application
identifier published in [OpenAI's Codex source](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs).
It is not the creator's account credential. You sign into your own account;
there is no personal client ID or API key to obtain for this route. Existing
clones need to update, regenerate the Xcode project and rebuild, preserving
their local signing settings as described in the guide.

Build 28 includes **Pair another Mac** recovery and preserves a healthy voice
connection when opening Settings. A second physical iPhone with another OpenAI
account completed pairing, audible voice, the correct Mac transcript and a
successful physical CarPlay test using the existing developer team.
**Another Apple signing team and free Personal Team signing remain unverified.**
The direct Remote protocol and voice attestation are experimental
and may reject a build or change upstream. Public availability of the client ID
is not an assurance of OpenAI support for this third-party integration.

Optional Voice task creation and automation changes remain disabled by default.
The direct route uses the desktop app's Remote connection; you do not start a
separate App Server listener. The alternative standalone App Server WebSocket
transport is still unimplemented. See [Connections](docs/CONNECTIONS.md).

One further privacy point: App Server failure messages can include diagnostic
details such as local paths, and those messages may travel through the Realtime
service. Only use the experimental connection with a host whose diagnostic
disclosure you are comfortable with.

## Lore and origin

The name is not subtle. **Nightblood** is the gloriously enthusiastic sword
from Brandon Sanderson's Cosmere.

This is a fan-made tribute, not an official Cosmere product. The face, code and
voice prompt are original project work, not a reproduction of the character,
Sanderson's writing or anyone else's artwork.

My two-year-old son named the second face **Marshmallow**. That was the whole
naming process. I have no notes.

## My first open-source project

This is also my first ever open-source project.

It started with a slightly odd question: could an AI companion feel less like a
chat window and more like a small living presence? I am releasing it because I
want to learn in public, improve the rough edges and see what other people make
from the same starting point.

There will be rough edges. I believe that is traditional.

## Built with Codex and Claude

I built NightBlood Remote with help from both OpenAI Codex and Anthropic Claude.
They contributed in different ways at different stages, alongside a fairly
unreasonable amount of iteration from me.

## From Blender to a live face

I started the first NightBlood face in Blender. That was where I worked out the
stage, lighting, eye shape, smoke, drift and the visual language for listening,
thinking, speaking and failure.

Blender was the laboratory, not the final renderer. Once the face felt right, I
translated the look into a live WebGL shader that could react at frame rate to
gaze, voice amplitude and the state of the conversation on the phone.

That split turned out to be one of the most useful ideas in the project. Blender
is where I discover and judge the character. The shipping app expresses the
result as a small set of runtime parameters. The full route is in
[Face creation](docs/FACE_CREATION.md).

## What I hope people try

- Invent a genuinely different third face with its own movement grammar, not
  just NightBlood in a new colour.
- Build better bridges between Blender material and motion studies and runtime
  shader parameters.
- Add accessible alternatives for reduced motion, gaze tracking and audio-led
  animation.
- Implement the documented, authenticated Codex App Server transport without
  weakening the native/WebView credential boundary.
- Use the face with another voice or agent system by replacing the transport,
  while keeping camera processing local and permissions explicit.

## What is included

- A SwiftUI portrait app, Live Activity extension and native CarPlay surface.
- CarPlay connection and error states, Reconnect, and an intro image that switches to the face on Talk.
- Desktop transcript attachment and rendering/startup performance improvements.
- Secure Enclave P-256 device identity and a Face ID session gate.
- Device-only Keychain storage for tokens and pairing metadata.
- WebRTC microphone and speaker handling in a media-only `WKWebView` on the phone and native WebRTC in CarPlay.
- Two live WebGL faces with gaze, state, colour and amplitude animation.
- Generic procedural startup chimes with no third-party audio samples.
- Blender 5.2 scene-generation and rendering scripts.
- Unit tests for prompt, lifecycle, routing and heartbeat behaviour.
- A repeatable local privacy and secret scan.

## Requirements

- macOS with Xcode 26, or a compatible version supporting Swift 6 and iOS 18.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45 or later.
- Node.js 20.19 or later (or 22.12 or later) and npm.
- A physical Face ID iPhone for Secure Enclave, DeviceCheck, TrueDepth and real
  microphone and speaker testing.
- Developer Mode enabled on that iPhone for installation through Xcode. Enable
  it, restart and confirm Turn On as described in [Setup](docs/SETUP.md).
- For the experimental direct connection: Codex access and Remote Control
  enabled for the same account/workspace on the Mac and phone. Managed
  workspaces may require an administrator to enable Remote Control separately.
  Complete the Mac's Remote setup before phone enrolment; see [Setup](docs/SETUP.md#1-prepare-the-mac).
- A current Codex desktop app; see the [tested desktop version](docs/SETUP.md#desktop-version-compatibility).
- Blender 5.2 or later, but only if you want to regenerate the design studies.

## Build the safe Simulator demo

```bash
npm --prefix app/ui ci
make ios-project
open ios/NightBloodRemote/NightBloodRemote.xcodeproj
```

Choose the `NightBloodRemote` scheme and an iPhone Simulator.

The Simulator is useful for the faces, layout and deterministic lifecycle work.
It cannot prove Secure Enclave, Face ID, DeviceCheck, TrueDepth or real two-way
audio.

The generated `.xcodeproj` is deliberately ignored so that local Apple team
and signing data do not wander into a commit.

## Before a physical-device build

1. Follow [Setup](docs/SETUP.md) and read [Security](SECURITY.md).
2. Generate the project, then set your own bundle identifiers and Apple team
   for the app and Live Activity extension in the ignored Xcode project.
3. **Choose CarPlay or phone-only before installing.** CarPlay is enabled in
   the project by default, but Apple must approve the capability for your
   team/app. Enable it on your explicit App ID and use a development profile
   that includes the entitlement and the target phone. Follow the
   [CarPlay signing steps](docs/SETUP.md#carplay-signing-and-first-launch).
   If you choose the documented phone-only build instead, NightBlood will
   work on the phone but **will not appear in CarPlay**.
4. Keep the included public OAuth client configuration. Sign in to your own
   ChatGPT account on both devices.
5. Leave `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` set to `NO` unless you have
   reviewed and accepted the bounded host changes described in Connections.
6. Leave `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` set to `NO` unless you have
   reviewed and accepted persistent task creation with inherited permissions.
7. Build and inspect the signing summary before installing. Regeneration
   replaces local Xcode edits; record and reapply them before another build.

## Fork setup: the blanks are deliberate

The public snapshot removes every value that identified the original Apple
developer, iPhone, Mac, Codex account, task or saved project. A fork therefore
needs its own local configuration.

| Blank or example | What a fork should do |
|---|---|
| `com.example.nightblood.remote` | Replace it with bundle IDs controlled by the fork owner |
| `DEVELOPMENT_TEAM: ""` | Select the fork owner's team in the ignored generated Xcode project |
| `CODEX_OAUTH_CLIENT_ID` | Public upstream application ID is supplied; use your own account at sign-in |
| `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION: NO` | Keep `NO` unless the fork owner deliberately enables persistent Voice task creation in an ignored local build setting. No project ID is needed |
| `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS: NO` | Keep `NO` unless the fork owner deliberately enables Voice heartbeat creation and deletion in an ignored local build setting |
| Empty Codex task field | Paste a task link or task UUID locally in Settings before a real session. Only its canonical UUID is persisted |
| No generated `.xcodeproj` | Run `make ios-project` and do not commit the result |
| No `.blend` or rendered face files | Regenerate the studies from the included Blender scripts |

The Simulator can render both faces but cannot establish physical-device
enrolment or voice. A missing-client-ID error means the app was built from old
or overridden configuration; follow [the upgrade steps](docs/SETUP.md#updating-an-existing-clone).
Never copy account tokens, pairing state or private keys from another build.

After changing a fork, run:

```bash
npm --prefix app/ui ci
npm --prefix app/ui run typecheck
make audit
make simulator-build
```

If the face resource is missing, run
`npm --prefix app/ui run build:ios-direct` and regenerate the Xcode project.

If signing fails, inspect only your local bundle IDs, team and profiles. If a
real connection fails, use the staged diagnosis in
[Connections](docs/CONNECTIONS.md). Do not weaken the native/WebView boundary,
add a LAN listener or retry a pairing change when the outcome is uncertain.

Enabling `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` lets the Realtime model ask
the paired host to create persistent local tasks using its existing workspace
and permission context.

Enabling Voice automations also permits the app to create or delete its own
heartbeat files on the paired host. Neither operation gets a separate Face ID
prompt after the session has started. Read the full bounded-authority section
in [Connections](docs/CONNECTIONS.md) before enabling either feature.

## Documentation

- [Connect your Mac and iPhone](docs/SETUP.md)
- [Instructions for setup agents](AGENTS.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Every connection and trust boundary](docs/CONNECTIONS.md)
- [Create and adapt the faces with Blender and WebGL](docs/FACE_CREATION.md)
- [Privacy behaviour](PRIVACY.md)
- [Security policy and limitations](SECURITY.md)
- [What was removed or sanitised](docs/SOURCE_AUDIT.md)
- [Pre-publication audit checklist](docs/PUBLICATION_CHECKLIST.md)

## Local verification

```bash
make audit
make web
make ios-project
make simulator-build
make test-build
```

`make audit` is intentionally conservative. Review every exception yourself.
A passing script is useful evidence, not proof that a release is safe.

`make test-build` proves that the test target compiles without starting a
device. To run the tests, first boot a Simulator you have chosen and then use
its exact name:

```bash
xcrun simctl list devices available
make simulator-test SIMULATOR='iPhone 17 Pro'
```

Simulator tests do not replace a physical-device pass for Face ID, Secure
Enclave, DeviceCheck, TrueDepth, background audio or real WebRTC media.

## Licence and names

The code, original scripts, procedural chimes and included original visual
assets are available under the MIT Licence. See [LICENSE](LICENSE) and
[NOTICE](NOTICE.md).

OpenAI, ChatGPT and Codex are trademarks of OpenAI. This project is independent
and is not endorsed by OpenAI.

Please review the project and character names before a public launch. The
licence does not grant rights in anyone else's marks, however enthusiastic the
sword may be.
