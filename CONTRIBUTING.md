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

Real account and physical-device tests must use the contributor's own devices,
accounts, bundle identifiers and explicitly issued credentials. Test values
belong in local Xcode settings or the Keychain, never in fixtures or commits.
