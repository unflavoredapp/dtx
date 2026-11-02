# Decrypt.team for iOS

Native app for [Decrypt.team](https://decrypt.team): search the apps in your repos, see their versions, download or hand them to a sideloader, and open the website's Studio (decrypt + inject on the server) inside the app.

- **Search**: AltStore/SideStore style repos. `https://delvek.net/repo.json` is the starting repo; add your own under **Repos**.
- **Studio**: the website in a web view, sharing its sign-in. Finished IPAs download straight to the share sheet / Files.
- **Settings**: server address.

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

## Next
Plugin system (analysis tools such as Ghidra headless, class-dump) as server jobs with results shown in the app.
