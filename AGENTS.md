# Helping someone set up NightBlood Remote

Read README.md, docs/SETUP.md and docs/CONNECTIONS.md before giving connection
instructions. The public OAuth application ID is deliberate, published
upstream and not a user credential. Do not blank it, ask for an API key, or
tell users to obtain a personal OAuth client ID for this experimental route.

Check the current branch and local changes first. Preserve local signing
configuration. The supported preparation commands in this release are:

```sh
npm --prefix app/ui ci
make ios-project
```

There is no `make setup` or `make doctor` yet. Project regeneration replaces
local Xcode edits. Follow docs/SETUP.md for both target bundle IDs, Apple team
and the phone-only Code Signing Entitlements setting. Do not request CarPlay
approval just to test the phone. Do not commit generated Xcode projects or
per-owner configuration.

Guide the owner through the exact Connection-screen stages: Sign in to ChatGPT,
Enrol this iPhone, Claim code once, select an online Mac, Confirm this exact
Mac, then select the local Codex task. The human completes sign-in, verification,
Face ID and pairing consent. Never collect passwords, tokens or pairing codes
into source files, logs or the chat. Never copy another app's credentials.

The desktop host must be signed into the same account/workspace, running,
online and awake. Do not start a separate App Server listener, expose a port,
patch the installed desktop app or change system security settings. Preserve
PKCE/state validation, device proof, host binding and task permission checks.
An uncertain pairing or mutation is not permission to replay it.

Explain a failure at its actual stage: build/signing, browser sign-in, enrolment,
pairing, host confirmation, task attachment or voice attestation/media. Keep
normal host approvals available; do not disable them to make setup pass.

For code changes, run the relevant checks from CONTRIBUTING.md. For setup,
verify audible two-way voice and the correct Mac task with the owner. A build,
Simulator result or login success does not establish a working connection.
Fresh-account/device/signing tests are still pending for the interim fix;
report exact tested combinations. CarPlay needs its own physical vehicle test.

Do not push or publish changes unless the owner explicitly requests it.
