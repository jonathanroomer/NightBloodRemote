# NightBlood Remote for iPhone

NightBlood Remote was not a carefully planned or particularly well thought out
product. It started as a fun experiment: could I give the latest voice models a
face and a personality, inspired by some of the brilliant characters in my
favourite books?

On the iPhone, that means an animated WebGL face, full-duplex WebRTC audio,
local TrueDepth gaze input and a Lock Screen Live Activity. I have also included
the Blender scripts I used to work out the original face design and its
different listening, thinking, speaking and failure states.

This is a clean public-source snapshot of the private iOS 1.6.0 prototype. It
contains no private Git history, developer-team identifier, provisioning
profile, device identifier, host name, bearer token, account identifier,
personal prompt text or sampled voice clip.

## One important connection caveat

The face works and the Simulator demo works. The direct Codex Remote connection
is a different matter. It is **experimental reference code**, not a generally
available public integration.

In particular:

- There is no OpenAI first-party OAuth client ID in this repository.
- OpenAI does not currently document a public registration flow for a
  third-party Codex Remote iPhone controller.
- The private relay route also requires third-party DeviceCheck acceptance.
- Task creation and host automation changes are disabled by default. Both need
  deliberate local configuration.
- Please do not borrow a client ID from Codex, ChatGPT or another installed
  application. That is not a clever shortcut. It is someone else's identity.

The supported public Codex integration surface is Codex App Server. Its remote
WebSocket transport is documented, although still experimental. This repository
does not yet implement that alternative transport. Read
[Connections](docs/CONNECTIONS.md) before trying to connect a real account.

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

- A SwiftUI portrait app and Live Activity extension.
- Secure Enclave P-256 device identity and a Face ID session gate.
- Device-only Keychain storage for tokens and pairing metadata.
- WebRTC microphone and speaker handling inside a media-only `WKWebView`.
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

1. Read [Connections](docs/CONNECTIONS.md) and [Security](SECURITY.md).
2. Replace the example bundle identifiers in
   `ios/NightBloodRemote/project.yml` with identifiers you control.
3. Select your own Apple development team locally in Xcode or in your private
   copy of `project.yml`.
4. Leave `CODEX_OAUTH_CLIENT_ID` blank unless OpenAI has issued an OAuth client
   registration for this exact application.
5. Leave `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` set to `NO` unless you have
   reviewed and accepted the bounded host changes described in Connections.
6. Leave `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` set to `NO` unless you have
   reviewed and accepted persistent task creation with inherited permissions.
7. Regenerate the project, build it and inspect the signing summary before
   installing it.

## Fork setup: the blanks are deliberate

The public snapshot removes every value that identified the original Apple
developer, iPhone, Mac, Codex account, task or saved project. A fork therefore
needs its own local configuration.

| Blank or example | What a fork should do |
|---|---|
| `com.example.nightblood.remote` | Replace it with bundle IDs controlled by the fork owner |
| `DEVELOPMENT_TEAM: ""` | Select the fork owner's team in the ignored generated Xcode project |
| `CODEX_OAUTH_CLIENT_ID: ""` | Leave it blank for the demo unless OpenAI explicitly issues one for that application |
| `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION: NO` | Keep `NO` unless the fork owner deliberately enables persistent Voice task creation in an ignored local build setting. No project ID is needed |
| `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS: NO` | Keep `NO` unless the fork owner deliberately enables Voice heartbeat creation and deletion in an ignored local build setting |
| Empty Codex task field | Paste a task link or task UUID locally in Settings before a real session. Only its canonical UUID is persisted |
| No generated `.xcodeproj` | Run `make ios-project` and do not commit the result |
| No `.blend` or rendered face files | Regenerate the studies from the included Blender scripts |

The expected safe-demo behaviour is for both faces to build and render while
account sign-in reports that no Codex Remote OAuth client ID is configured.
That is intentional, not a missing source file.

Please do not “repair” it by copying an identifier from Codex, ChatGPT, this
project's private history or somebody else's build.

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
