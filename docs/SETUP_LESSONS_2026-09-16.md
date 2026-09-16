# Build 28 setup lessons and verification, 16 September 2026

This is the handover from physical setup troubleshooting. The repeatable order
is in [AGENTS.md](../AGENTS.md), with user-facing steps in [Setup](SETUP.md).
Preserve the working phone, host account, selected task and task permissions
while testing another device. These notes contain no real account/device IDs.

## What was established

| Stage | What happened | Instruction or fix |
|---|---|---|
| Build configuration | The public OAuth client ID was blank and stopped sign-in. | Keep the reviewed public upstream ID. Update the clone, regenerate and rebuild without losing local signing. No personal client ID or API key is required for this route. |
| Connection documentation | “Public App Server transport not implemented” was mistaken for the direct route being absent. | Explain that the demo uses the desktop's private Remote relay. The separate standalone WebSocket alternative is unimplemented. Do not install a LAN bridge/listener to complete this setup. |
| Apple signing | The second phone's owner had no developer membership. | The existing developer team can register and sign for that test device. Configure app and extension together. A signing certificate alone does not establish device-registration access or an inclusive profile. |
| Device preparation | Trust alone did not enable development. A locked device can also block preparation. | Enable Developer Mode, restart, confirm Turn On and unlock to the Home Screen. Read the underlying Xcode device-preparation error rather than repeatedly rebuilding. |
| Foreground authentication | The second phone later stopped at “Face ID required” before any Remote attempt. The tester resolved it and reached the earlier desktop error. | Check the local Face ID gate separately from Mac access. Passcode unlock is insufficient for the current app gate. Preserve the enrolled identity; a generic biometrics error is not evidence that pairing or Mac permissions changed. |
| Provisioning | A new phone needed a matching development profile. | Use automatic signing/device registration or the Apple developer portal. If downloaded manually, confirm the actual file exists locally and includes the intended phone, App ID/team and required capabilities before building. A browser Download click is not proof the build tools have the file. |
| CarPlay | The original phone works in the car. The second phone initially had a phone-only signed app and wildcard profile without CarPlay, so it did not appear there. An explicit App ID and matching CarPlay profile fixed it; the owner then confirmed it worked fully in the car. | Keep CarPlay enabled by default in Git. Explain the capability/App ID/profile/device steps before installation, and the missing car app when deliberately choosing phone-only. Verify both signed entitlement and profile for each target phone. Free Personal Team and another team's DeviceCheck acceptance remain unverified. |
| Workspace access | Another account had Codex access but immediate enrolment HTTP 403. Remote Control was disabled by its workspace administrator. | Check workspace/role Remote permission before phone enrolment, then complete this Mac's own Remote setup. Once enabled, that test reached enrolment, pairing and host confirmation. Not every 403 necessarily has this cause. |
| Task selection | A confirmed Mac still did not make Voice ready while the task field was empty. | Require the local task link/UUID for the exact paired host/account. Pairing status and Ready to talk are different. Preserve task permissions if asking its agent for the UUID. |
| Task permissions | The original working task changed from full access to a restricted workspace profile during testing. Its helper was then denied. | Check live task settings separately from workspace Remote permission. An exact-policy probe reproduced the denial. Restoring that owner's approved original task-specific full access restored phone voice without another install. Keep approval settings and global defaults intact. |
| Older desktop | Read-only inspection of 26.623.141536 (4753) found a live IPC router in the user's temporary directory, while NightBlood requires the Codex-home socket. Remote pairing and helper execution worked. | The endpoint mismatch is confirmed; older protocol compatibility was not tested. Use the latest approved desktop. Updating only the CLI does not update desktop IPC. The owner chose to document this limitation and move to a current host rather than add legacy compatibility. |
| Settings lifecycle | Home reached Ready to talk and voice worked, but opening Settings produced a secure connection error. | Opening Settings invoked setup reconciliation, which invalidated and replaced the prepared connection. Build 26 removes that refresh. A view-hosting regression fails before and passes after the fix, and the original phone passed the physical checks. The precise earlier live relay rejection was not captured. |
| Diagnostics | An old generic desktop error concealed permission denial. | Keep distinct endpoint, policy, connection, handshake and timeout reasons. Return only allowlisted codes, never arbitrary helper exceptions, tokens, paths or conversation snapshots. |

## Prevent another permission regression

The voice task's effective permission profile is a dependency of desktop
attachment. Preserve it across ordinary prompts, task resume, handoff and setup
work. Do not use the working voice task to carry another device's UUID or run
diagnostic model turns. Do not copy the setup task's default restrictions onto
it. Compare live settings before/after a change and verify the actual helper
under the resulting policy, then verify the phone.

The observed restricted profile denied the Unix socket even when ordinary file
access was available. Merely enabling legacy network access was not sufficient
in the tested configuration. A narrowly allowed socket plus a network proxy
passed a local probe, but the loaded desktop did not recognise a newly added
profile without refreshing its configuration. That alternative was not
completed on the phone. Do not distribute it as a proven recipe or leave an
unused global profile/proxy experiment installed.

Agent instructions can prevent an agent from silently changing settings, but
cannot lock out manual or upstream changes. A remaining product improvement is
an explicit preflight that detects an incompatible effective task policy and
shows a bounded, actionable error before Voice preparation. It must fail
clearly rather than automatically grant full access. Preserve the owner's
ability to choose a restricted task and normal approval handling.

## Build 28 acceptance and compatibility

- The original phone passed Settings open/close, Settings during voice, two
  conversations, correct transcript, voice after reopening and CarPlay. Its
  approved task permissions and approvals were preserved.
- The second phone used another OpenAI account and the existing Apple team.
  After workspace Remote was enabled, it completed enrolment and pairing.
  The older desktop was abandoned after the endpoint mismatch was confirmed;
  no legacy compatibility was added.
- On the current desktop, Pair another Mac preserved sign-in and enrolment.
  The new task initially denied the helper under Workspace access. The owner
  explicitly chose task-specific Full access, preserving its existing granular
  approvals and reviewer. Audible voice and the intended transcript passed.
- The second phone then received build 28 with its existing bundle and Keychain
  identity, an explicit App ID and a profile including that phone and CarPlay.
  Signed entitlements, profile contents and installed version were verified.
  The owner confirmed it worked fully in physical CarPlay. This is user-reported
  end-to-end acceptance; individual locked-phone, mute and recovery subcases
  were not separately recorded for this phone.
- The second phone runs iOS 26.6.2. Both current hosts use desktop 26.908.70816
  (9275), bundled App Server 0.154.0-alpha.6.2. The app code passed 39 focused
  Swift lifecycle/CarPlay tests and 11 desktop-helper tests. Build 28 retains
  the tested build 27 app logic and enables CarPlay in the second phone's local
  signing configuration. Public source has no personal signing values.
- Another Apple signing team, free Personal Team signing and future desktop
  versions remain unverified. Each fork must perform its own enrolment, voice
  and physical-car checks; simulator success does not prove these.

## Additional host-profile lesson

A separate desktop test profile initially used a Codex-home path too long for
its Unix socket. A shorter profile path resolved the EINVAL listen error.
This is a custom-profile troubleshooting check, not a normal setup step.
Preserve credentials and app data within that profile; never copy another
user's authentication or change the working profile to fix a test instance.
A separate macOS user or another current Mac is the simpler documented test
route. Neither needs a modified desktop binary.

## Keep future installs repeatable

Use the ordered [setup guide](SETUP.md) and [agent instructions](../AGENTS.md):
current desktop and workspace Remote permission; host Remote enablement;
selected task and agreed permissions; build/signing choice; Trust and Developer
Mode; browser authorisation and enrolment; one-time pairing and exact host
confirmation; task UUID; phone voice verification; then parked CarPlay.

CarPlay stays enabled by default. Explain the Apple capability/profile/device
step before installation. Use phone-only signing only as an explicit choice,
with the consequence that the app will not appear in CarPlay. When upgrading,
preserve ignored signing settings, bundle identity, Keychain, pairing and the
voice task's approved permissions. Regenerating the Xcode project overwrites
local signing edits, so record and reapply them.

Build 28 includes the Settings lifecycle fix, Pair another Mac recovery and
bounded enrolment/attachment diagnostics. A persistent ignored signing config,
dedicated signing schemes, a setup/preflight command and automatic detection
of incompatible task policy remain future improvements, not existing commands
or guarantees. No code automatically broadens a task's permissions.
