# Privacy

## Summary

NightBlood Remote contains no analytics SDK, advertising SDK or crash-reporting
service. It does not persist microphone audio, camera frames or conversation
transcripts. A real voice session still sends audio and transcript events to
the configured OpenAI service, subject to that service and account's terms and
retention settings.

## Data by component

| Component | Data handled | Persistence | Network |
|---|---|---|---|
| TrueDepth gaze tracker | Face/head pose converted to six bounded numbers | None | None; numbers go only to the bundled face |
| WebRTC media page | Microphone stream, remote audio, amplitude and transcript events | None | WebRTC media connection when a real session starts |
| Swift voice model | Task ID, state and up to 100 in-memory transcript items | Memory only | Through the configured controller transport |
| Keychain stores | OAuth token set, controller metadata and confirmed environment binding | `WhenUnlockedThisDeviceOnly` | Used only for authenticated connection operations |
| Secure Enclave | Non-exportable P-256 private key | Device-bound | Only public identity and signatures leave the device |
| Live Activity | Conversation state and local controls | Managed by iOS | No transcript content is placed in the activity |
| Procedural cue generator | Synthesised PCM samples | None | None |

## Permissions

- **Camera:** provides local gaze/head-pose numbers. Frames are not retained or
  sent to JavaScript, the Mac or a server.
- **Face ID:** authorises the foreground control session and Secure Enclave key
  use. Biometric templates remain managed by iOS.
- **Microphone:** feeds the active WebRTC voice session. It is stopped when the
  session ends.
- **Background audio:** permits an established conversation to continue while
  the app is backgrounded. It does not start a new session.

## What downstream forks must review

Adding analytics, logging, a new transport, a crash reporter, notifications,
cloud storage or a backend changes this statement. Update the privacy notice,
permission strings and App Store privacy disclosures before distribution.
