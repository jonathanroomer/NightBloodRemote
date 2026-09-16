# Connect your Mac and iPhone

## Status of the 16 September setup fix

Earlier public builds stopped before sign-in because `CODEX_OAUTH_CLIENT_ID`
was empty. The project now supplies the public application identifier from
[OpenAI's Codex source](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs).
It is not an account credential. You authorise your own account in the browser.
No personal OAuth client ID or OpenAI API key is needed for this route.

This is an interim fix for that configuration error. A fresh public build has
not yet completed enrolment, pairing and two-way voice using another person's
OpenAI account and Apple signing identity. The Remote protocol is experimental
and upstream acceptance can vary. Report the stage that fails rather than
assuming a build or successful sign-in proves the whole connection works.

## 1. Prepare the Mac

- Install/update the ChatGPT/Codex desktop app, sign in and confirm a local
  Codex task works. Use the same account and workspace later on the phone.
- Open **Settings → Connections → Control this Mac → Set up** or **Add**.
  Complete the displayed verification and allow Remote access. A managed
  workspace may require its administrator to enable it.
- Keep the desktop app running and the Mac online and awake. Use its
  **Keep this Mac awake** setting when appropriate.
- Choose a local Codex task in the project you want voice to use. Keep its
  normal sandbox and approvals. Obtain its local task link or UUID, not a
  published conversation-share link. If needed, ask the desktop agent to
  identify the intended task's local link. Do not post that value in an issue.

OpenAI documents the host controls in [Remote connections](https://learn.chatgpt.com/docs/remote-connections).
Desktop labels can vary by version. The installed 26.908.70816 desktop source
also provides a manual eight-character pairing PIN alongside the pairing flow.
If your version shows no usable manual code, stop and report the version; do
not assume scanning into the official ChatGPT app pairs NightBlood too.

For this direct route, do not launch a separate `codex app-server --listen`
process, open a router/LAN port, or install a NightBlood Mac companion. The
bundled transcript helper starts automatically through the paired App Server.
It needs `/usr/bin/python3` and a compatible running desktop app.

## 2. Build for your iPhone

You need Xcode and its command-line tools, XcodeGen 2.45 or later, Node/npm
(the UI requires Node 20.19+ or 22.12+), and a physical Face ID iPhone for the
real connection. An unsigned Simulator build is useful for the face and layout,
but cannot validate DeviceCheck, Secure Enclave enrolment or real voice.

```sh
git clone https://github.com/jonathanroomer/NightBloodRemote.git
cd NightBloodRemote
npm --prefix app/ui ci
make ios-project
open ios/NightBloodRemote/NightBloodRemote.xcodeproj
```

There is no `make setup` or `make doctor` command in this interim release.

In the generated Xcode project:

1. Select the **NightBloodRemote** app target. Set a unique bundle identifier
   you control and select your Apple development team in Signing & Capabilities.
2. Do the same for **NightBloodLiveActivity**, using the same team and a distinct
   identifier prefixed by your app's identifier, for example with `.liveactivity`.
3. **Phone-only, without CarPlay approval:** on the app target, open Build
   Settings, choose All, search **Code Signing Entitlements**, and clear its
   value for the configuration you will build. This omits the managed CarPlay
   entitlement from that signed product. It does not disable Face ID or
   bypass device attestation. Leave the tracked entitlement file unchanged.
   This signing workaround is not yet physically verified for a fresh account.
4. Keep `CODEX_OAUTH_CLIENT_ID` at the supplied value. Leave the optional
   `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` and
   `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` settings at `NO` for the initial test.
5. Connect and trust your iPhone, enable Developer Mode if Xcode requests it,
   select the **NightBloodRemote** scheme and the physical device, then Run.
   Review any signing/profile error before proceeding.

Generated project edits are local and ignored by Git. **Running `make ios-project`
again replaces them.** Record your team, bundle IDs and phone-only entitlement
choice privately so you can reapply them. Persistent local configuration and
dedicated phone/CarPlay schemes are follow-up improvements, not part of this fix.

CarPlay needs a paid developer account and separate managed capability approval.
Free Personal Team signing and DeviceCheck have not been verified for this app;
do not assume a free signing success proves a working connection.

## 3. Authorise and pair NightBlood

1. Open NightBlood's gear-shaped **Connection** settings and complete Face ID
   if requested.
2. Tap **Sign in to ChatGPT**. Complete the OpenAI browser flow with the same
   account/workspace as the Mac. Expected state: **Signed in — enrol this iPhone**.
3. Tap **Enrol this iPhone** and complete the additional Remote authorisation.
   Expected state: **Enter the code shown by Codex**. This step creates this
   app installation's own device-bound controller.
4. On the Mac, use **Add** in its Remote connection settings to show a fresh
   one-time code. Enter it in NightBlood's **One-time Mac code** field and tap
   **Claim code once**. Do not reuse a code already claimed by another app.
5. Refresh paired Macs if needed, select the intended online Mac, then tap
   **Confirm this exact Mac**. An unknown pairing outcome requires verification,
   not repeatedly submitting the same operation.
6. In **Codex task**, paste your chosen local task link or canonical task UUID.
   It must belong to that host/account. The app stores only the canonical UUID.
7. Tap **Done** and wait for desktop preparation. NightBlood must attach the
   selected task before allowing Voice. Use **Reconnect** if setup is ready
   but the connection needs refreshing.
8. Tap the voice/start control, complete Face ID and microphone permission,
   then speak. Camera permission is for local gaze tracking.

Check that you hear an answer, the face reacts, and the intended Mac task shows
the conversation. Ask a harmless question about that task's workspace. For an
action test, choose a disposable workspace and request a small reversible edit.
Approve any host request through its normal interface. NightBlood does not
provide a general approval-answering tool; keep the desktop task available if
an approval needs attention.

Test Stop, reopening and Reconnect. A mobile-data test can then check the relay
outside the local Wi-Fi network. No earlier action should be replayed.

## 4. Optional features and CarPlay

The selected task can already act according to its own permissions. The two
optional build switches control additional tools, not a read-only mode:

- `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION=YES` enables persistent new tasks using
  the selected task's workspace and permission context. No project ID is needed.
- `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS=YES` enables creation/deletion of the
  voice task's own heartbeat files on the host.

Enable only the capabilities you want in local app-target build settings and
rebuild. Read [Connections](CONNECTIONS.md#bounded-voice-tool-authority) first.

For CarPlay, finish phone setup first. Obtain Apple's **Voice Based Conversation**
entitlement approval for your developer account/app, enable it on your App ID
and refresh provisioning. Restore the app target's Code Signing Entitlements
value to `NightBloodRemote/NightBloodRemoteCarPlay.entitlements`, then rebuild.
Apple explains the [entitlement and profile process](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements).
Membership alone does not transfer the creator's approval to your app.

The CarPlay integration requires iOS 26.4 or later. Test while parked: app
visibility, locked-phone launch after first unlock, vehicle microphone/speakers,
the first sentence, microphone mute, speaker mute, Stop and Reconnect.

## Updating an existing clone

1. Record your local signing choices privately. Run `git status` and preserve
   any local source edits; do not discard or overwrite them to update.
2. If the branch is clean and follows upstream `main`, run `git pull --ff-only`.
   Fork owners should fetch/merge the upstream change using their usual flow.
3. Run `npm --prefix app/ui ci`, then `make ios-project`.
4. Reapply team, bundle IDs and any phone-only entitlement choice in Xcode.
   Check the effective `CODEX_OAUTH_CLIENT_ID` is non-empty and not overridden
   by an older blank local setting. Build and install again.

Keep a working app's bundle ID unchanged when updating it. For a separate
account experiment, use a distinct app and extension bundle ID, optionally a
different display name, so the original installation is preserved. Do not add
shared Keychain access groups or copy credentials between them.

## Troubleshooting and account tests

| Symptom | Next step |
|---|---|
| Missing OAuth client ID | Follow the upgrade steps and inspect effective app-target settings. An API key is not the solution. |
| Browser login fails | Check the account/workspace and redacted OAuth error. The iPhone's callback ports are loopback-only. |
| Enrolment fails or lacks fresh password authentication | Report that stage and login method. The current validator requires a fresh `pwd_auth_time` claim; SSO/passkey compatibility is not established. Do not remove the check. |
| Pairing outcome unknown | Refresh paired-Mac state before deciding on another attempt. |
| No online Mac | Check same account/workspace, Remote enabled, desktop app running and Mac awake; refresh. |
| Desktop attachment failed | Check `/usr/bin/python3`, the selected task and desktop compatibility. Do not change IPC socket permissions or patch the desktop app. |
| Voice attestation failed | Check physical device/signing and record the redacted failure. Never invent a DeviceCheck proof. |
| CarPlay signing error | Use the phone-only setting until your App ID/profile has Apple's approval. |

For reports, include the public commit, app/build, Xcode, iOS and desktop app
versions, which stage failed and a redacted error. Do not include passwords,
tokens, pairing codes, task links, device IDs or raw authentication logs.

Another OpenAI account can be tested on the same iPhone with a separately
installed build, but the Mac host must use that same test account/workspace.
A separate macOS user or test Mac can preserve the working desktop session.
Do not sign the active host out in the middle of work. This checks account
compatibility; it does not independently test another phone or Apple team.

There is not yet a polished sign-out/reset screen. Uninstalling is not proof of
upstream revocation or Keychain cleanup. For cleanup, use the desktop connection
controls to revoke only the test controller and verify it can no longer connect.
See [Revocation and local reset](CONNECTIONS.md#revocation-and-local-reset).
