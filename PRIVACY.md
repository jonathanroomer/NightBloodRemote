# Privacy

## Summary

NightBlood Remote contains no analytics SDK, advertising SDK or crash-reporting
service. The app itself does not persist microphone audio, camera frames or its
local transcript display. A real voice session sends audio, prompts, transcript
events and bounded tool results to the configured OpenAI/Codex service and
paired host. Those systems may persist conversation and task transcripts under
their own account, product and retention settings.

## Data by component

| Component | Data handled | Persistence | Network |
|---|---|---|---|
| TrueDepth gaze tracker | Face/head pose converted to six bounded numbers | None | None; numbers go only to the bundled face |
| WebRTC media page | Microphone stream, remote audio, amplitude and transcript events | None | WebRTC media connection when a real session starts |
| Swift voice model | Canonical task UUID, state and up to 100 transcript items | Task UUID in app preferences until changed or the app is removed; transcript display is memory only | Through the configured controller transport |
| Keychain stores | OAuth token set, controller metadata and confirmed environment binding | `WhenUnlockedThisDeviceOnly` | Used only for authenticated connection operations |
| Secure Enclave | Non-exportable P-256 private key | Device-bound | Only public identity and signatures leave the device |
| DeviceCheck attestation | Apple token, bundle ID, up to 16 preferred language tags, locale, time zone, combined screen dimensions in points, screen scale, a per-launch app-session UUID and token-generation latency | None in this app | Apple receives the token request; the experimental controller service receives the encoded attestation envelope |
| Bounded Voice task tools | New-task prompt/title/model choice; created-task title, status and bounded message text; current-workspace availability | Created tasks and their messages are persisted by the paired Codex host; the app keeps only session-scoped receipts | Tool requests/results traverse the experimental controller and Realtime service. The model receives a synthetic project alias/path, never an account-specific project ID or host filesystem path |
| Voice automation tool | Heartbeat name, prompt, schedule, target task UUID and notification status | Disabled by default; when deliberately enabled, creates or deletes an automation directory on the paired host | Bounded tool requests/results traverse the experimental controller and Realtime service |
| Live Activity | Conversation state and local controls | Managed by iOS | No transcript content is placed in the activity |
| Procedural cue generator | Synthesised PCM samples | None | None |

## Permissions

- **Camera:** provides local gaze/head-pose numbers. Frames are not retained or
  sent to JavaScript, the Mac or a server.
- **Face ID:** authorises the foreground control session and Secure Enclave key
  use. After that gate succeeds, permitted task or automation tools do not ask
  for Face ID again individually. Biometric templates remain managed by iOS.
- **Microphone:** feeds the active WebRTC voice session. It is stopped when the
  session ends.
- **Background audio:** permits an established conversation to continue while
  the app is backgrounded. It does not start a new session.

## What downstream forks must review

Adding analytics, logging, a new transport, a crash reporter, notifications,
cloud storage or a backend changes this statement. Update the privacy notice,
permission strings and App Store privacy disclosures before distribution.
Enabling task creation or Voice automations also requires a threat-model review
of the paired host, its sandbox/approval policy and the service's retention.
