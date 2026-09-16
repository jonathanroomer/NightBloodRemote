# Contributing

Keep changes narrow and reviewable. Do not commit generated Xcode projects,
signing data, credentials, device or host identifiers, recorded audio, camera
frames, transcripts, `.blend` binaries, renders or build artefacts.

Before opening a change:

```bash
make audit
make web
make simulator-build
```

For connection work, read [Setup](docs/SETUP.md) and [AGENTS.md](AGENTS.md).
Real account and physical-device tests must use the contributor's own devices,
accounts and bundle identifiers. The reviewed public OAuth application ID is
build configuration, not a user credential. Account tokens and local signing
values belong in the Keychain or ignored Xcode settings, never in fixtures or
commits. Report the exact setup stage reached; compiling is not a voice test.
