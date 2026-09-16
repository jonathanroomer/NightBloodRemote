# Helping someone set up NightBlood Remote

Read [Setup](docs/SETUP.md), [Connections](docs/CONNECTIONS.md) and the
[16 September setup lessons](docs/SETUP_LESSONS_2026-09-16.md) first. Follow this
order and report the actual stage reached. A successful build, login or Mac
pairing is not proof that Voice works.

## Preserve a working setup before doing anything else

Check the branch and local changes. Record app/build, desktop version, intended
phone, account/workspace, host, task and effective task permission settings in
private local notes. Keep identifiers and credentials out of public files and
issues. Preserve local signing configuration and the original phone app.

Treat the working voice task's permissions as part of its connection setup.
Before and after any task resume, prompt, handoff or settings change, check its
effective permission profile, filesystem/network policy, approval policy and
reviewer against the known working values. Do not assume a global config file
describes an already running task.

Do not apply this setup agent's default `:workspace` profile to the voice task,
send another phone's test UUID into it, or use it for diagnostic model turns.
Keep debugging in the setup task. An already authorised task-specific repair
may proceed, but do not silently broaden or narrow access, change global
defaults, or disable approvals as a shortcut. Verify the effective live settings
after any approved change. If they drift, explain the difference and restore
only the owner's authorised choice. Do not keep changing unrelated settings.

## Setup order

1. **Mac and account first.** Use a current desktop app approved for that Mac
   and confirm Codex works locally. Check the same account and workspace will
   be used on the phone. In managed workspaces, verify the administrator has
   enabled Remote Control for the user or role. Codex access alone is not
   sufficient. SSH-only Connections is a reason to check policy and version.
   Check [desktop compatibility](docs/SETUP.md#desktop-version-compatibility):
   the working desktop is 26.908.70816 (9275). An older 26.623.141536 (4753)
   uses a different IPC location and does not work with this helper. Recommend
   the latest approved desktop; a newer CLI alone does not update desktop IPC.
   Do not implement legacy endpoint/protocol fallbacks for this setup. If IT
   blocks an update, use an approved current installation instead.
2. **Enable this Mac's Remote host.** Complete its own Remote setup, keep it
   running, online and awake. Workspace permission and host enablement are
   separate steps. Do not add a standalone App Server listener, LAN port or
   NightBlood Mac companion for this direct route.
3. **Choose the task and check its permissions.** Use the intended local task
   on that exact host. The bundled helper needs `/usr/bin/python3` and access
   to the stock desktop IPC socket under the task's effective policy. Follow
   [the permission check](docs/SETUP.md#selected-task-permissions). Never infer
   socket access from a readable file or a successful unrestricted shell probe.
4. **Prepare the phone build.** Run `npm --prefix app/ui ci`, then
   `make ios-project`. The supplied public `CODEX_OAUTH_CLIENT_ID` is deliberate
   and is not a user credential. Do not blank it or ask for an API key/personal
   OAuth client ID. Configure both app and extension bundle IDs and Apple team
   locally. CarPlay stays enabled by default in tracked project settings.
   Before installing, explain the Apple capability/profile step in
   [CarPlay signing](docs/SETUP.md#carplay-signing-and-first-launch). Verify
   the explicit App ID, signed entitlement and profile's inclusion of the
   target device; one phone's working profile does not establish another's.
   If CarPlay is not approved, explain that the optional phone-only build
   will not appear in the car before using that local signing setting.
   Never commit a phone-only override or private provisioning material.
   There is no `make setup` or `make doctor` yet.
5. **Prepare the device.** Connect, Trust, enable Developer Mode, restart,
   confirm Turn On, then unlock and keep the phone awake. Register that device
   with the signing team and ensure the development profile includes it.
   A tester's phone can use the developer's existing team without the tester
   buying membership. This does not prove free Personal Team compatibility.
6. **Authorise and pair.** Guide the human through Sign in to ChatGPT, Enrol
   this iPhone, the additional verification, Claim code once, selecting the
   intended online Mac, and Confirm this exact Mac. The human completes login,
   Face ID and pairing consent. Never collect passwords, tokens or pairing
   codes into chat, source or logs. Do not copy another app's credentials.
7. **Select the voice task.** Paste its local task link or canonical UUID in
   the required Codex task field. Prefer an existing local task link. If the
   intended task's agent reads `CODEX_THREAD_ID`, preserve that task's permission
   selection before and after the request. Never substitute the setup agent's
   UUID or a public conversation-share link. Tap Done and wait for desktop
   attachment and Ready to talk.
   When changing hosts, stop Voice and use **Pair another Mac** (build 27),
   then confirm the new host and choose its task. Keep sign-in/enrolment intact.
   Refresh only lists existing pairings. Never reset an uncertain code claim.
8. **Verify the result.** Test audible two-way voice and the intended Mac task
   with the owner, then Stop, a second conversation, Settings open/close,
   foreground return and explicit Reconnect. Test a harmless workspace read
   before an authorised disposable edit. Preserve host approvals. Unknown
   pairing/start/stop outcomes must be reconciled, never blindly replayed.
9. **Expand only after phone success.** Test the alternate account/device on
   its own matching Mac account without signing out the working host. CarPlay
   follows phone acceptance and needs its own entitlement/profile and parked
   physical-car test. Simulator checks do not prove device enrolment or audio.

## Diagnose and preserve the connection

Keep these stages distinct: build/signing, browser sign-in, enrolment, pairing,
host confirmation, task attachment, and voice attestation/media. An immediate
enrolment HTTP 403 is not a Python/transcript fault. Check workspace Remote
enablement first without assuming every 403 has that cause.

For attachment failures, distinguish endpoint missing, permission denied,
connection refused, handshake/owner mismatch and timeout. Older builds can hide
permission denial behind `desktop_unavailable`. Use only bounded diagnostics.
Do not chmod the desktop socket, edit Codex databases or patch its installed
binary. The documented older build has a confirmed endpoint mismatch; other
version differences still need evidence. Never equate pairing with compatible
desktop attachment or promise that every future build will work.

Simply opening Settings must not restart setup or tear down healthy prepared
Voice. Keep launch/foreground recovery and explicit refresh actions distinct
from inspecting the connection. Preserve failure visibility and exact host/task
binding rather than making the status label look successful.

For code changes, run relevant checks from CONTRIBUTING.md. Project regeneration
replaces local Xcode edits, so preserve/reapply signing choices. Do not commit
generated projects, signing profiles, private prompts, real task/device IDs or
private repository history. Report exact tested combinations and pending checks.
The setup lessons document records candidate fixes that are not released yet.
Do not push or publish changes unless the owner requests it.
