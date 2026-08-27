# Public-source audit record

This file explains the sanitisation decisions for reviewers. It contains no
private values; omitted examples are described by category only.

| Risk area | Public-package decision |
|---|---|
| Git identity and historical commits | New local repository with fresh, generic metadata; private history excluded |
| Apple signing | Developer team, certificates, profiles, devices and generated Xcode project excluded |
| Bundle identifiers | Replaced with `com.example` placeholders |
| OAuth application identity | First-party identifier removed; tracked setting is blank |
| Codex account metadata | Task, saved-project, host, environment, controller and account defaults removed |
| Personal prompt text | Rewritten to address a generic user |
| Personal UI labels and permission text | Rewritten to refer to the device owner or paired Mac |
| Local paths | Scripts made portable; absolute home-directory paths rejected by audit |
| Audio | Recorded/sample cues removed; generated procedural chimes retained |
| Blender artefacts | Scripts/profiles retained; `.blend`, renders and caches excluded |
| Xcode products | Projects, archives, derived data and user data excluded |
| Private companion product | Mac/Raspberry Pi application, specifications and operations documentation excluded |
| iOS fallback experiments | Unused LAN/fallback sources excluded from the signed public target |
| Personal story | Only the specifically approved README facts are retained |
| AI provenance | Codex and Claude collaboration acknowledged without private transcripts or detailed attribution |

## What the automated audit checks

`scripts/audit-public-source.sh` scans tracked working files for common secret
forms, home paths, email addresses, Apple team IDs, OAuth application IDs,
private keys, private IPv4 addresses and known account-linked UUID shapes. It
also rejects common signing, Xcode-user, Blender, audio and video artefacts and
checks committed author metadata.

The scanner deliberately excludes its own pattern definitions. A successful
result means those specific patterns were absent; it does not prove the source
is anonymous, legally clear or secure.

## Remaining review points

- The direct Codex Remote protocol is experimental and not a public third-party
  registration path.
- The project and character naming needs an independent fan-use/trademark
  decision before publication.
- A maintainer security-contact route must be selected before launch.
- The owner requested a second, independent security audit before any remote
  is added or anything is published.
