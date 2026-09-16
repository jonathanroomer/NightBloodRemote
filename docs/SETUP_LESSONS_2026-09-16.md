# Setup lessons and remaining checks, 16 September 2026

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
| Provisioning | A new phone needed a matching development profile. | Use automatic signing/device registration or the Apple developer portal. If downloaded manually, confirm the actual file exists locally and includes the intended phone, App ID/team and required capabilities before building. A browser Download click is not proof the build tools have the file. |
| CarPlay | A team's capability approval does not transfer to every fork. | Test phone-only first if the new signing identity lacks CarPlay approval. Preserve the tracked entitlement file and apply the documented local build setting. Free Personal Team and another team's DeviceCheck acceptance remain unverified. |
| Workspace access | Another account had Codex access but immediate enrolment HTTP 403. Remote Control was disabled by its workspace administrator. | Check workspace/role Remote permission before phone enrolment, then complete this Mac's own Remote setup. Once enabled, that test reached enrolment, pairing and host confirmation. Not every 403 necessarily has this cause. |
| Task selection | A confirmed Mac still did not make Voice ready while the task field was empty. | Require the local task link/UUID for the exact paired host/account. Pairing status and Ready to talk are different. Preserve task permissions if asking its agent for the UUID. |
| Task permissions | The original working task changed from full access to a restricted workspace profile during testing. Its helper was then denied. | Check live task settings separately from workspace Remote permission. An exact-policy probe reproduced the denial. Restoring that owner's approved original task-specific full access restored phone voice without another install. Keep approval settings and global defaults intact. |
| Older desktop | The second phone's selected task could not attach on a company-managed older desktop. | Record the version and bounded diagnostic. Respect company update policy. Age alone is not a proven root cause, especially after a similar symptom occurred on the current original Mac. |
| Settings lifecycle | Home reached Ready to talk and voice worked, but opening Settings produced a secure connection error. | Opening Settings invoked setup reconciliation, which invalidated and replaced the prepared connection. A candidate removes that automatic refresh. A view-hosting regression fails before and passes after the fix. The precise live relay rejection was not captured. |
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

## Current verification and release boundary

- The earlier public OAuth/configuration fix was pushed. These additional
  onboarding lessons and the pending recovery work are not a new public release.
- A second phone with another Codex account completed sign-in, enrolment,
  pairing and Mac confirmation after the workspace admin change. It used the
  existing Apple developer team. Task attachment/two-way voice remain pending.
- The original phone, still on private diagnostic build 24, was reported fully
  working from Home after the task permission repair. Its Settings issue is
  separate and still awaits an updated installation.
- Private candidate build 26 compiles and passes strict signing checks, 37
  voice/CarPlay simulator tests and 11 helper tests. It contains the Settings
  fix and newer bounded diagnostics. It has not been installed or physically
  accepted. Do not label these changes as shipped in the public snapshot.
- Another Apple signing team, free Personal Team signing, the new phone-only
  entitlement path and complete fresh-account voice remain unverified. A
  simulator or an unchanged Mac companion cannot prove the phone's Secure
  Enclave, DeviceCheck, Face ID, relay identity or physical audio path.

## Resume in this order

1. Install the prepared candidate on the original phone, preserving its app
   identity, account, pairing, task and working permission settings.
2. Verify cold launch, Ready to talk, Settings open/close twice, a real voice
   conversation, Stop and another conversation. Check Settings during voice,
   foreground return and explicit Reconnect without replaying earlier actions.
3. Resume the second-phone test against its matching account/host. Capture its
   current bounded error before choosing a fix. Do not assume the original
   phone's permission failure explains the other host's missing endpoint.
4. Move only reviewed, sanitised fixes into the public source. Run its audit
   and relevant checks. Preserve blank team, generic bundle IDs, empty task
   field, generic prompts and disabled optional mutation switches.
5. Update the setup status to the exact combinations actually verified. Keep
   remaining signing/account limitations visible. CarPlay has a separate parked
   physical acceptance check. Give the requester a tested process afterwards.

Additional improvements to consider after the physical check: a persistent
ignored signing configuration, distinct phone-only/CarPlay schemes, an actual
setup/preflight command, clearer task-selection onboarding and the policy
preflight above. These are follow-up work, not commands or features available
in the interim public fix.
