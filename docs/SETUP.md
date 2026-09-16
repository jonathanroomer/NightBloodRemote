# Connect your Mac and iPhone

## Status of the 16 September setup fix

Earlier public builds stopped before sign-in because `CODEX_OAUTH_CLIENT_ID`
was empty. The project now supplies the public application identifier from
[OpenAI's Codex source](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs).
It is not an account credential. You authorise your own account in the browser.
No personal OAuth client ID or OpenAI API key is needed for this route.

Build 27 has completed enrolment, pairing, audible two-way voice and the correct
Mac transcript on a second physical iPhone using another OpenAI account and
the existing Apple developer team. Another Apple signing team and free
Personal Team signing remain unverified. The Remote protocol is experimental
and upstream acceptance can vary. Report the stage that fails rather than
assuming a build or successful sign-in proves the whole connection works.

A physical test on 16 September reached browser sign-in with another Codex
account on a second iPhone, signed by the existing developer team. Its initial
enrolment request returned HTTP 403 before the additional authorisation screen.
The test workspace's administrator then found Remote Control disabled; enabling
it made the desktop Remote controls appear. The tester subsequently completed
phone enrolment, Mac pairing and host confirmation. Task attachment then failed
after about 20 seconds on an older, company-managed desktop app that could not
be updated. A read-only check on that Mac confirmed that its older desktop
uses a different IPC endpoint from the one this helper requires. Moving the
test to a separate account profile on the current desktop and explicitly
granting that test task Full access resolved attachment. The tester confirmed
audible voice and the transcript in the new task.

## 1. Prepare the Mac

- Install/update the ChatGPT/Codex desktop app, sign in and confirm a local
  Codex task works. Use the same account and workspace later on the phone.
- **Check workspace Remote Control permission before starting phone setup.**
  If you use a managed workspace, ask its administrator to check that Remote
  Control is enabled for your user or role in the workspace's admin settings.
  Ordinary Codex access does not establish this permission. If Connections
  shows only SSH, check this permission and the desktop app version; SSH setup
  does not enable phone Remote Control. After an admin change, reopen
  Connections (restart the app if needed) and confirm the host controls appear.
- Open **Settings → Connections → Control this Mac → Set up** or **Add**.
  Complete the displayed verification and allow Remote access on this Mac.
  Workspace permission and this host's Remote setting are separate checks.
- Keep the desktop app running and the Mac online and awake. Use its
  **Keep this Mac awake** setting when appropriate.
- Choose a local Codex task in the project you want voice to use. Record and
  preserve its effective permissions and approvals, then check the helper can
  run under that policy as described below. Obtain its local task link or UUID,
  not a published conversation-share link. Do not post that value in an issue.

OpenAI documents the host controls in [Remote connections](https://learn.chatgpt.com/docs/remote-connections).
Desktop labels can vary by version. The installed 26.908.70816 desktop source
also provides a manual eight-character pairing PIN alongside the pairing flow.
If your version shows no usable manual code, stop and report the version; do
not assume scanning into the official ChatGPT app pairs NightBlood too.

For this direct route, do not launch a separate `codex app-server --listen`
process, open a router/LAN port, or install a NightBlood Mac companion. The
bundled transcript helper starts automatically through the paired App Server.
It needs `/usr/bin/python3` and a compatible running desktop app.

### Desktop version compatibility

Use the latest Codex desktop app approved for your Mac. The original phone's
voice, transcript, Settings and reconnect checks passed on **26.908.70816,
build 9275**, with bundled App Server **0.154.0-alpha.6.2**. This is a verified
combination, not a claimed minimum version or a guarantee for future releases.

A second host running desktop **26.623.141536, build 4753** successfully paired
but failed with `desktop_endpoint_missing`. Its running App Server was
**0.145.0**, selected through a `CODEX_CLI_PATH` override, while the bundled
version was **0.142.5**. Its desktop IPC router used the older per-user
temporary location, `codex-ipc/ipc-<uid>.sock`. NightBlood's helper requires
`<effective Codex home>/ipc/ipc.sock`. The read-only host check confirmed the
older socket was live, so the observed failure was the endpoint mismatch,
not missing Remote permission or a failed App Server startup. Compatibility
of that older router's transcript protocol was not tested.

**Update the desktop application, not just the CLI.** NightBlood does not
provide a fallback for that older IPC location. Do not create socket links,
broaden task permissions or start another listener to work around it. If a
company manages updates, ask IT to approve a current desktop or test on an
approved current installation elsewhere. Preserve the working account and
task permissions when switching test hosts; choose a task belonging to the
new host rather than retaining the previous host's task UUID.

### Selected task permissions

Workspace Remote Control permission lets the phone reach the Mac. The selected
task's file/network permission profile separately governs the transcript helper
that must attach before Voice becomes ready. Pairing does not grant that helper
access to the desktop's local Unix socket.

Record the selected task's current permission profile, filesystem/network
restrictions and approval settings before setup. Use the desktop's task
permission controls to review them. Keep the same settings when sending a
message, resuming the task or switching between setup and voice work. A setup
agent must not replace them with its own defaults. Reading global configuration
alone does not prove the effective settings of an already running task.

On 16 September, the original working voice task had changed from full access
to a restricted workspace profile. The bundled helper failed under that exact
restricted profile and succeeded under the previous full-access policy.
Restoring the owner's explicitly authorised, task-specific full file/network
access restored voice on the existing iPhone build. No app reinstall, new
pairing or API key was needed for that repair. Approval settings were preserved.

The second account's newly created task also began with restricted Workspace
access and reported `desktop_permission_denied`. With the owner's explicit
agreement, setting Full access on that task alone enabled voice on build 27.
Both tasks retained their distinct approval settings. A new task's default
restrictions and a previously working task's permission drift are separate
causes; inspect the live task in either case.

Full access is broad access for the selected task, not a mandatory global
default for every user. Do not enable it silently. If a task is intentionally
restricted, diagnose the helper under that exact policy and agree an appropriate
task-specific choice with its owner. A narrower socket/proxy configuration
passed a local probe but has not passed the complete phone flow and is not a
supported copy-and-paste setup recipe yet.

File read permission, ordinary network access or a successful unrestricted
Terminal test does not establish Unix-socket access inside the task sandbox.
Newly added named profiles may also be absent from the running desktop's cached
configuration. After an approved change, verify the task's live effective
settings and the app's desktop-attachment result. Do not chmod the socket,
change global defaults, edit Codex databases or auto-elevate the helper.

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
3. **Choose signing before installing.** The project enables CarPlay by
   default. To use it, complete [CarPlay signing](#carplay-signing-and-first-launch):
   Apple's capability approval, an explicit App ID with that capability,
   and a development profile that includes this phone and entitlement.
   These are Apple account/device steps; cloning Git cannot complete them.
   **Phone-only, without CarPlay approval:** on the app target, open Build
   Settings, choose All, search **Code Signing Entitlements**, and clear its
   value for the configuration you will build. This omits the managed CarPlay
   entitlement from that signed product. It does not disable Face ID or
   bypass device attestation. Leave the tracked entitlement file unchanged.
   **This build will not appear in CarPlay**, even if phone voice works.
   This option passed on a second phone/account using the existing developer
   team; a different signing team remains unverified.
4. Keep `CODEX_OAUTH_CLIENT_ID` at the supplied value. Leave the optional
   `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION` and
   `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS` settings at `NO` for the initial test.
5. Connect the unlocked iPhone to the Mac and accept **Trust This Computer**
   on the phone. In **Settings → Privacy & Security → Developer Mode**, turn
   Developer Mode on, restart, then confirm **Turn On** and enter the phone's
   passcode when prompted. Developer Mode is required for this Xcode-installed
   build. If the setting is missing, first pair the phone with Xcode.
6. Unlock the phone to its Home Screen and keep it awake while Xcode prepares
   and installs the app. Select the **NightBloodRemote** scheme and the physical
   device, then Run. With automatic signing, accept device registration if
   Xcode requests it. Review any signing/profile error before proceeding.

A tester does not need their own Apple developer membership when you sign the
build with your existing developer team and register their phone for testing.
Their Apple/iCloud account can stay unchanged. This tests your team's signing;
it does not establish that free Personal Team signing works. See Apple's
[registered-device testing](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
and [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

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
   This field is required even after the Mac is paired. To obtain the UUID,
   prefer an existing local task link. If a UUID is needed, check the intended
   task's permission selection, then ask its Codex agent:
   **Read CODEX_THREAD_ID from your environment and show me this task's UUID.**
   Verify its permissions remain unchanged afterwards. Copy the result directly
   into NightBlood, not into another working voice task. Do not use a public
   share link or the setup agent's UUID from a different Mac.
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

Test Stop, a second conversation, Settings open/close, reopening and Reconnect.
Opening Settings should preserve a healthy prepared connection. The 16 September
fix removes an unnecessary Settings refresh and passed the original phone's
physical retest. Build 27 also passed voice and transcript on the second account. See
[setup lessons](SETUP_LESSONS_2026-09-16.md) for release status.
A mobile-data test can then check the relay outside the local Wi-Fi network.
No earlier action should be replayed.

### Change to another Mac

Stop voice, then open Connection and tap **Pair another Mac**. Enter a fresh
code from the new desktop's Remote setup, claim it once, select the new Mac and
tap **Confirm this exact Mac**. Your account and enrolled iPhone identity stay
in place. NightBlood clears the old task selection; paste a task link or UUID
from the new Mac. You can also choose **Choose an already paired Mac**.

Refresh paired Macs only lists existing pairings; it cannot pair a new host.
Older builds omitted the return to code entry after confirming a Mac. Update
to build 27 for that recovery action. An uncertain or unverified code claim
must be reconciled first; the action does not reset or replay it.

## 4. Optional features and CarPlay

The selected task can already act according to its own permissions. The two
optional build switches control additional tools, not a read-only mode:

- `NIGHTBLOOD_ENABLE_VOICE_TASK_CREATION=YES` enables persistent new tasks using
  the selected task's workspace and permission context. No project ID is needed.
- `NIGHTBLOOD_ENABLE_VOICE_AUTOMATIONS=YES` enables creation/deletion of the
  voice task's own heartbeat files on the host.

Enable only the capabilities you want in local app-target build settings and
rebuild. Read [Connections](CONNECTIONS.md#bounded-voice-tool-authority) first.

### CarPlay signing and first launch

CarPlay is enabled by default in the tracked project. Before installing a
CarPlay build, complete these signing steps:

1. Obtain Apple's **Voice Based Conversation** capability approval for your
   developer team/app. In Certificates, Identifiers & Profiles, use an
   **explicit App ID** matching the app's bundle identifier and enable the
   approved capability. A wildcard phone-only profile is insufficient.
2. Register the target iPhone with that team. Generate or refresh its iOS
   development provisioning profile with that App ID, development certificate
   and phone selected. Automatic signing can manage the profile when the
   capability is available to the team/App ID. Keep the extension's signing
   consistent with the app.
3. Keep the app target's Code Signing Entitlements set to
   `NightBloodRemote/NightBloodRemoteCarPlay.entitlements`; restore it if you
   previously chose phone-only testing. Use the updated profile and rebuild.
4. Before installation, verify the signed app and embedded profile both allow
   `com.apple.developer.carplay-voice-based-conversation`, and that the profile
   includes the target iPhone. A working profile for another phone is not enough.
   Keep profiles, certificates and device/team identifiers out of Git.
5. Install and finish phone authorisation, pairing and voice verification.
   While parked, connect that phone to CarPlay and open NightBlood from the
   car's app grid; it need not open automatically. Check the other app pages
   and **iPhone Settings → General → CarPlay → your car → Customise** if needed.
   If absent from that list, check the installed build's signing first.

Apple explains the [entitlement and profile process](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements).
Membership alone does not transfer the creator's approval to your app.
See also Apple's [CarPlay app arrangement instructions](https://support.apple.com/en-gb/108415).

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
| Developer Mode disabled | Enable it on the phone, restart, confirm Turn On, and unlock before installation. Trusting the Mac alone is not enough. |
| “Face ID is required before NightBlood can control this Mac” | This is the phone's local unlock gate, before Remote. Check that the owner's Face ID works and NightBlood is allowed under Settings → Face ID & Passcode → Other Apps. A passcode-unlocked phone is not an authenticated NightBlood session. The current generic message can also cover biometric lockout; do not change Mac permissions or re-pair to fix it. See [Apple's Face ID app controls](https://support.apple.com/en-gb/108411). |
| Developer disk image could not be mounted | Read the underlying Xcode error. If it says the device is locked, unlock to the Home Screen and keep it awake while Xcode prepares it. Report other underlying errors instead of repeatedly rebuilding. |
| No Accounts / profile does not include this device | Sign into the intended developer account in Xcode Settings → Apple Accounts, select its team and let automatic signing register the phone. An existing certificate can sign a build without being able to register a new phone. Alternatively, register the phone and create/download a matching development profile through Apple's developer website. |
| Browser login fails | Check the account/workspace and redacted OAuth error. The iPhone's callback ports are loopback-only. |
| Connections shows only SSH / Control this Mac is missing | Check the desktop app is current and ask the workspace administrator to enable Remote Control for your user or role. Reopen Connections after the change, then complete this Mac's Remote setup. Availability may also vary by rollout. |
| HTTP 403 immediately on Enrol this iPhone | This is enrolment start, before device-key creation or Mac pairing. Check official Remote availability and enablement for the same account/workspace; ordinary Codex access alone is not proof. Record the displayed stage, response format and any recognised service code. An HTML refusal may come from a network or edge service. The status alone does not establish the cause; do not change app identity or bypass verification to force access. |
| Enrolment fails or lacks fresh password authentication | Report that stage and login method. The current validator requires a fresh `pwd_auth_time` claim; SSO/passkey compatibility is not established. Do not remove the check. |
| Pairing outcome unknown | Refresh paired-Mac state before deciding on another attempt. |
| Mac paired, but Voice says Choose a Codex task / Codex Remote unavailable | Fill in the required Codex task link or UUID field with a task from that Mac, then tap Done and wait for preparation. Earlier builds misleadingly called the pairing stage Ready for NightBlood Voice even with this field empty. Actual voice readiness is Ready to talk. |
| No online Mac | Check same account/workspace, Remote enabled, desktop app running and Mac awake; refresh. |
| Selected Mac unavailable and you want a different Mac | In build 27, stop voice and use **Pair another Mac**, then explicitly confirm the new host and choose its own task. Keep your existing sign-in and enrolment. Refresh alone cannot add a new pairing. |
| Desktop attachment failed | Check `/usr/bin/python3`, the selected task and desktop compatibility. Keep the task open on the paired Mac. Use a current desktop version approved for that machine; if company policy blocks an update, test on an approved current installation elsewhere. Newer NightBlood builds report a fixed failure code to distinguish helper execution, desktop handshake, task attachment and timeout. Do not change IPC socket permissions or patch the desktop app. |
| `desktop_permission_denied`, or an old build's `desktop_unavailable` after previously working | Compare the selected task's live permission profile with its known working settings. Check the helper under that exact policy. Follow the task-specific permission procedure above, preserving approvals and global defaults. |
| `desktop_endpoint_missing` | Check the paired Mac, intended task, actual Codex home and desktop version. Older desktops may use a different socket location even when pairing works. Follow [desktop compatibility](#desktop-version-compatibility) and update the desktop app through the approved process. A CLI update alone is insufficient. Do not broaden permissions or re-enrol to fix an absent endpoint. |
| `desktop_connection_refused`, reset, handshake failure or timeout | Check whether the desktop/socket is still alive and compatible. Record the bounded code and desktop version. Do not assume Python is missing or change signing because attachment timed out. Some detailed codes exist only in the pending diagnostic candidate. |
| Voice works from Home but opening Settings produces a secure-connection error | Older builds unnecessarily restart setup when Settings appears. The fix passed the original phone's physical checks in build 26 and is in the public experiment; check release status before updating. In the earlier observed case, reopening the app and starting voice from Home works. This symptom does not by itself call for re-enrolment or more permission changes. |
| Voice attestation failed | Check physical device/signing and record the redacted failure. Never invent a DeviceCheck proof. |
| CarPlay signing error | Use the phone-only setting until your App ID/profile has Apple's approval. |
| Voice works on the phone but NightBlood is absent from CarPlay | A phone-only build omits the required entitlement. Complete the CarPlay signing steps, including this phone in the profile, and reinstall; do not change Codex pairing to fix app visibility. |

For reports, include the public commit, app/build, Xcode, iOS and desktop app
versions, which stage failed and a redacted error. Do not include passwords,
tokens, pairing codes, task links, device IDs or raw authentication logs.

Enrolment error diagnostics retain only the stage, HTTP status, response format
and a fixed set of recognised service codes. Unknown codes and arbitrary server
messages are intentionally omitted. Enrolment completion with an uncertain
outcome still requires review and is never automatically retried.

Another OpenAI account can be tested on the same iPhone with a separately
installed build, but the Mac host must use that same test account/workspace.
A separate macOS user or test Mac can preserve the working desktop session.
Do not sign the active host out in the middle of work. This checks account
compatibility; it does not independently test another phone or Apple team.

There is not yet a polished sign-out/reset screen. Uninstalling is not proof of
upstream revocation or Keychain cleanup. For cleanup, use the desktop connection
controls to revoke only the test controller and verify it can no longer connect.
See [Revocation and local reset](CONNECTIONS.md#revocation-and-local-reset).
