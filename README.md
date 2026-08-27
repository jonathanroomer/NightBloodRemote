# NightBlood Remote for iPhone

NightBlood Remote is an experimental SwiftUI iPhone shell for an animated
WebGL companion face, full-duplex WebRTC audio, local TrueDepth gaze input and
a Lock Screen Live Activity. The repository also includes the Blender scripts
used to establish the original face design and state vocabulary.

This is a clean public-source snapshot derived from the private iOS 1.6.0
prototype. It intentionally contains no private Git history, developer-team
identifier, provisioning profile, device identifier, host name, bearer token,
account identifier, personal prompt text or sampled voice clip.

## Important connection status

The visual application and Simulator demo are complete and buildable. The
direct Codex Remote connection is **experimental reference code**, not a
generally available public integration:

- no OpenAI first-party OAuth client ID is included;
- OpenAI does not currently document a public registration flow for a
  third-party Codex Remote iPhone controller;
- the private relay route also requires third-party DeviceCheck acceptance;
- do not copy a client ID from Codex, ChatGPT or another installed app.

The supported public Codex integration surface is Codex App Server. Its remote
WebSocket transport is documented but experimental; this repository does not
yet implement that alternative transport. Read [Connections](docs/CONNECTIONS.md)
before attempting a real account connection.

## Lore and origin

The name **Nightblood** comes from Nightblood, the gloriously enthusiastic
sword in Brandon Sanderson's Cosmere. This is a fan-made tribute, not an
official Cosmere product, and the face, code and voice prompt here are original
project work rather than a reproduction of the character or Sanderson's text.

The second face is **Marshmallow**. My two-year-old son named that one, which is
both the entire naming process and a difficult result to improve upon.

## My first open-source project

This is my first ever open-source project. It began as a personal experiment:
could an AI companion feel less like a chat window and more like a small,
living presence? Releasing it is an invitation to learn in public, improve the
rough edges together and see what other people make from the same idea.

## Built as a collaboration

NightBlood Remote was developed with both OpenAI Codex and Anthropic Claude,
with each contributing in different ways at different stages. It was a real
team effort between a human idea, two AI collaborators and a great deal of
iteration. This repository presents the resulting work without publishing
private conversations or attempting line-by-line attribution.

## From Blender to a live face

The first NightBlood face was developed in Blender: stage, light, eye shape,
smoke, drift and a vocabulary of listening, thinking, speaking and failure
states. Blender became the visual laboratory, not the shipping renderer. The
accepted look was then translated into a live WebGL shader so it could react at
frame rate to gaze, voice amplitude and conversation state on the phone.

That split remains one of the most useful ideas in the project: use Blender to
discover and judge the character, then express the final visual grammar as
small runtime parameters. The complete route is in
[Face creation](docs/FACE_CREATION.md).

## What I hope people try

- Invent a genuinely different third face, with its own movement grammar—not
  just a new colour palette.
- Create better bridges from Blender material and motion studies to runtime
  shader parameters.
- Add accessible alternatives for reduced motion, gaze tracking and audio-led
  animation.
- Implement the documented, authenticated Codex App Server transport without
  weakening the native/WebView credential boundary.
- Use the face with another voice or agent system by replacing the transport,
  while keeping camera processing local and permissions explicit.

## What is included

- SwiftUI portrait app and Live Activity extension.
- Secure Enclave P-256 device identity and Face ID session gate.
- Device-only Keychain stores for tokens and pairing metadata.
- WebRTC microphone/speaker handling inside a media-only `WKWebView`.
- Two live WebGL faces with gaze, state, colour and amplitude animation.
- Generic procedural startup chimes; no third-party audio samples.
- Blender 5.2 scene-generation and rendering scripts.
- Unit tests for prompt, lifecycle, routing and heartbeat behaviour.
- A repeatable local privacy/secret scan.

## Requirements

- macOS with Xcode 26 or a compatible version supporting Swift 6 and iOS 18.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45 or later.
- Node.js 20.19 or later (or 22.12 or later) and npm.
- A physical Face ID iPhone for Secure Enclave, DeviceCheck, TrueDepth and
  real microphone/speaker testing.
- Blender 5.2 or later only if you want to regenerate the design studies.

## Build the safe Simulator demo

```bash
npm --prefix app/ui ci
make ios-project
open ios/NightBloodRemote/NightBloodRemote.xcodeproj
```

Choose the `NightBloodRemote` scheme and an iPhone Simulator. The Simulator is
for face, layout and deterministic lifecycle work; it cannot prove Secure
Enclave, Face ID, DeviceCheck, TrueDepth or real two-way audio.

The generated `.xcodeproj` is deliberately ignored. This prevents local Apple
team and signing data from entering commits.

## Before a physical-device build

1. Read [Connections](docs/CONNECTIONS.md) and [Security](SECURITY.md).
2. Replace the example bundle identifiers in
   `ios/NightBloodRemote/project.yml` with identifiers you control.
3. Select your own Apple development team locally in Xcode or in your private
   copy of `project.yml`.
4. Leave `CODEX_OAUTH_CLIENT_ID` blank unless OpenAI has issued an OAuth client
   registration for this exact application.
5. Regenerate the project, build, and inspect the signing summary before
   installing it.

## Fork setup: deliberate blanks, not broken code

The public snapshot removes every value that identified the original Apple
developer, iPhone, Mac, Codex account, task or saved project. A fork therefore
needs its own local configuration:

| Blank or example | What a fork should do |
|---|---|
| `com.example.nightblood.remote` | replace with bundle IDs controlled by the fork owner |
| `DEVELOPMENT_TEAM: ""` | select the fork owner's team in the ignored generated Xcode project |
| `CODEX_OAUTH_CLIENT_ID: ""` | leave blank for the demo unless OpenAI explicitly issues one for that application |
| `CODEX_PROJECT_ID: ""` | optionally set an account-specific saved-project ID locally; blank disables Voice project listing/task creation |
| empty Codex task field | paste a task link or task UUID locally in Settings before a real session |
| no generated `.xcodeproj` | run `make ios-project`; do not commit the result |
| no `.blend` or rendered face files | regenerate studies from the included Blender scripts |

Expected safe-demo behaviour is that both faces build and render while account
sign-in reports that no Codex Remote OAuth client ID is configured. That is an
intentional boundary, not a missing source file. Do not “repair” it by copying
an identifier from Codex, ChatGPT, this project's private history or somebody
else's build.

After changing a fork, run:

```bash
npm --prefix app/ui ci
npm --prefix app/ui run typecheck
make audit
make simulator-build
```

If the face resource is missing, run `npm --prefix app/ui run build:ios-direct`
and regenerate the Xcode project. If signing fails, inspect only your local
bundle IDs, team and profiles. If a real connection fails, use the staged
diagnosis in [Connections](docs/CONNECTIONS.md); do not weaken the native/WebView
boundary, add a LAN listener or retry an uncertain pairing mutation.

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

`make audit` is intentionally conservative. Review every exception manually;
a passing script is not proof that a release is safe.

`make test-build` proves the test target compiles without starting a device.
To execute the unit tests, first boot a Simulator you have chosen, then use its
exact name:

```bash
xcrun simctl list devices available
make simulator-test SIMULATOR='iPhone 17 Pro'
```

Simulator tests do not replace a physical-device pass for Face ID, Secure
Enclave, DeviceCheck, TrueDepth, background audio or real WebRTC media.

## Licence and names

Code, original scripts, procedural chimes and included original visual assets
are available under the MIT Licence; see [LICENSE](LICENSE) and [NOTICE](NOTICE.md).
OpenAI, ChatGPT and Codex are trademarks of OpenAI. This project is independent
and is not endorsed by OpenAI. Review the project and character names before a
public launch; the licence does not grant rights in third-party marks.
