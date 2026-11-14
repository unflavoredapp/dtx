# Decrypt.team for iOS

Native app for [Decrypt.team](https://decrypt.team): search the apps in your repos, see their versions, download or hand them to a sideloader, and decrypt and inject on the server, all in native screens. The app uses the server only as a backend; it shows no website.

- **Home** (native): featured tools, search across your repos, changelog and live platform stats from the site.
- **Apps / Repos / Settings** (native): browse every app in your repos, add repos, set the server address. `https://delvek.net/repo.json` is the starting repo.
- **App page** (native): versions, saved dylibs and frameworks, store info, **Tools** (server plugins such as Load Commands and Strings), download or hand to a sideloader.
- **Decrypt & Inject**: a native screen. Pick the source (the repo's IPA, or the App Store version if it's newer), choose the inject path and folder, add your own .dylib or .framework folder, tap the app's existing load commands to strip them, optionally change its name, bundle ID or minimum iOS, and the server builds it. dtx.dylib is always injected. Then download the IPA, copy the link, or open it in a sideloader.
- **Sign in**: the site's login in a sheet; the app then uses the same session.

## Build an unsigned IPA on GitHub
1. Push this folder to a GitHub repo (branch `main`).
2. Open the **Actions** tab. **Build unsigned IPA** runs on every push (or press *Run workflow*).
3. Download `DecryptTeam-unsigned-ipa` from the run's artifacts. Tag a commit `v1.0.0` to also attach `DecryptTeam.ipa` to a release.

The IPA is **not signed**. Sign and install it with your own certificate (Feather, E-Sign, GBox, AltStore, …).

## Build locally
```
brew install xcodegen
xcodegen generate
open DecryptTeam.xcodeproj
```

## On-device OTA (tetherless.dev)

Local installs use **`*.tetherless.dev`** instead of the discontinued [backloop.dev](https://backloop.dev) service.

1. DNS: `*.tetherless.dev` → `127.0.0.1`. Apex `tetherless.dev` stays on the VPS for `pack.json`.
2. Pack: `./server/ota/scripts/gen-pack.sh` then deploy `server/ota/public/` to the tetherless.dev docroot (`./server/ota/scripts/deploy-public.sh`). See `server/tetherless-ota.md`.
3. The app **installs the pack on every launch** and offers the CA trust profile once; enable Full Trust in Certificate Trust Settings.
4. Install method stays **OTA (itms-services)** unless you switch to Native VPN install.

## Next
Plugin system (analysis tools such as Ghidra headless, class-dump) as server jobs with results shown in the app.
