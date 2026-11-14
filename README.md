# Uncrypt

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="180" alt="Uncrypt" />
</p>

<p align="center">
  Native iOS companion for <a href="https://decrypt.team">Decrypt.team</a> — search repos, decrypt & inject, sign, and install on-device.
</p>

## Features

### Browse & library
- Search apps across your repos (Delvek starter repo included)
- App pages with versions, store info, saved dylibs & frameworks
- Download IPAs or hand them to a sideloader

### Decrypt & inject
- Decrypt from the repo IPA or a newer App Store build
- Inject dylibs / frameworks, strip load commands, rename / re-ID
- Batch builds and Quick Build from device-installed apps
- `dtx.dylib` always injected on server builds

### AI assistant
- **Uncrypt** chat that runs decrypt / inject / analysis tools
- Dylib Studio, vision chats, recipes, and on-device knowledge

### Sign & install
- Import certificates / provisioning profiles
- On-device signer and signed builds library
- **OTA installs** over `*.tetherless.dev` (public pack auto-installed on launch)
- **Native installs** via built-in local VPN + pairing

### Tools & analysis
- Injector, Batch, Signer, Certificate manager
- App Info, Package, Info.plist, Binary, Bundles, Privacy
- Load Commands, Strings, Link Check
- Repo Studio, Updates, Live Update / plugins

### Account & extras
- Decrypt.team sign-in (same session as the site)
- DTX wallet, usage, daily scratch card
- Themes, changelog, live platform stats

## Build

**GitHub Actions** — push to `main`, download `DecryptTeam-unsigned-ipa` from the run artifacts. Tag `v1.0.0` to attach `DecryptTeam.ipa` to a release.

**Local**
```
brew install xcodegen
xcodegen generate
open DecryptTeam.xcodeproj
```

The IPA is **unsigned**. Sign it with your own certificate (Feather, E-Sign, GBox, AltStore, …).

## On-device OTA (tetherless.dev)

1. DNS: `*.tetherless.dev` → `127.0.0.1` (apex hosts `pack.json` on the VPS)
2. Generate & deploy the pack — see `server/tetherless-ota.md`
3. App pulls the pack on every launch; enable Full Trust for the pack CA once
