# 1.8.2 build 28 public source update

Build 28 includes the iPhone and CarPlay implementation from build 23 plus
the setup, connection recovery and diagnostic fixes tested on 16 September.
It remains an experimental source project, not a ready-to-install signed app.

## Changes

- Native CarPlay voice controls, separate startup and error labels, and a
  Reconnect action that does not replay earlier speech or actions.
- An intro image that switches to the animated face when Talk is pressed.
  The public source uses an Apple system terminal symbol. It does not bundle
  a vendor's desktop app icon.
- Full transparent CarPlay face animations, including the speaking mouth,
  violet working state and green ready flash.
- Native WebRTC for CarPlay while the phone keeps its media-only WebView path.
- Desktop transcript attachment before Voice starts, with stream identity
  checks and shutdown when the attachment becomes unavailable.
- Frame-loop, audio-processing and startup improvements.

## Public defaults

The public build starts without a selected task. The 16 September setup fix
supplies the public upstream Codex OAuth application ID, correcting the blank
configuration that previously blocked sign-in. Apple signing identity is blank
and bundle identifiers use `com.example`. Voice task
creation and automation writes remain disabled unless deliberately enabled in
local configuration. Generic prompts and procedural chimes replace personal
prompts and recorded sound-library clips. No signed binaries are included.

CarPlay requires iOS 26.4 or later and an Apple-approved Voice Based Conversation
entitlement. The ordinary iPhone deployment target remains iOS 18. The direct
Codex Remote connection retains its experimental registration and DeviceCheck
limitations described in [Connections](CONNECTIONS.md).

The [setup guide](SETUP.md) covers Mac and phone authorisation, upgrading an
existing clone, Developer Mode, workspace Remote permission, task permissions
and Apple CarPlay provisioning before installation. Build 28 includes
Pair another Mac recovery without deleting sign-in or enrolment,
preserves healthy voice when Settings opens, and distinguishes desktop failure
codes. A second account and physical iPhone (iOS 26.6.2) passed pairing, audible
voice, the correct Mac transcript and physical CarPlay use with the existing
developer team on desktop 26.908.70816 (9275). The original phone also passed
Settings, repeat conversations, reopening and CarPlay. Another signing team
and free Personal Team signing remain unverified. This does not add a
standalone App Server transport or account reset.

The code passed 39 focused Swift lifecycle/CarPlay tests and 11 desktop-helper
tests. The signed build and installed version were checked before the second
phone's successful car test. Build 28 changes signing/build identity from that
phone's phone-only build 27; its app logic is unchanged. CarPlay stays enabled
in the public project, but every builder must supply their own approved Apple
App ID and a profile that includes their test phone. See the consolidated
[setup lessons](SETUP_LESSONS_2026-09-16.md).

## Build and verification

Run `npm --prefix app/ui ci`, `npm --prefix app/ui run typecheck`, `make audit`
and `make ios-project`. Use `make simulator-test SIMULATOR='<device name>'`
with an available simulator. These checks do not establish real-account
eligibility, device signing approval or physical vehicle audio operation.

## Artwork generation

The source for the face atlases is included. Install `@playwright/test` in a
local, disposable tooling directory and set `PLAYWRIGHT_MODULE` to that
package's absolute location. Start the UI Vite server on loopback port 5197,
then run `node app/ui/scripts/export-carplay-artwork.mjs`. Only procedural
face images are produced. Do not commit local tooling paths or generated
project/signing files.
