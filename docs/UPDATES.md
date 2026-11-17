# In-app updates

## User flow

Install 1.1.0 manually once if you have 1.0.0. On Mac use **Minutes → Check for Updates…** (also in the menu bar); on Windows use **Check for Updates** in the toolbar. Confirm installation to download, replace the app and restart. Windows users must use the new Setup installer or Velopack portable package; the old raw ZIP is not update-enabled.

Updates are user-initiated. The app does not silently replace itself at startup. Recording and processing must finish before checking/installing; if a Mac task starts after downloading, Sparkle postpones relaunch until it finishes. Windows holds the capture and processing locks while updating. Notes are saved before exit. Workspaces and models are outside the application directory and must never be removed by an updater.

## macOS release

Sparkle 2.10.1 is pinned by Swift Package Manager. `Tools/embed-sparkle.sh` preserves its framework symlinks and signs its nested services before the app. `SUPublicEDKey` pins the update public key; the private Ed25519 key is stored in the releasing Mac's login Keychain by Sparkle's `generate_keys`. Back up that Keychain securely. Never commit/export the private key into the repository or release assets.

1. Increment `VERSION` and add a changelog entry; run `./build.sh` to increment `BUILD_NUMBER`.
2. Run `./release.sh` with the intended signing identity and optional `NOTARY_PROFILE`.
3. Download the matching Sparkle distribution from its official release and run:

   ```sh
   SPARKLE_TOOLS=/path/to/Sparkle/bin bash Tools/make-appcast.sh
   ```

4. Verify the app signature, DMG checksum, appcast archive URL/version/build and EdDSA signature. Test an older update-enabled app against the new feed before claiming the install/relaunch path is verified.
5. Publish the DMG and `dist/appcast.xml` together in the stable GitHub release. The app reads `https://github.com/chanpollo/minutes/releases/latest/download/appcast.xml`. Every subsequent stable release must include that feed and the Windows update assets; a platform-only latest release would break the other platform's feed.

The current Mac distribution uses an Apple Development signature and is not notarised. Developer ID signing and notarisation are recommended for smoother distribution; first installation can require Open Anyway. Do not rotate the update key casually: existing clients trust the embedded public key.

## Windows release

Velopack SDK and `vpk` are pinned to 1.2.161. `Program.Main` runs installer hooks before WinUI and the single-instance mutex. Automatic startup installation is disabled; the user confirms **Update & Restart**. The update source is the stable releases of `chanpollo/minutes` (prereleases excluded).

The Windows workflow tests, builds, bundles speech tools and packages:

- `Minutes-win-Setup.exe`: initial installation.
- `Minutes-win-Portable.zip`: portable installation with updater support.
- `Minutes-<version>-full.nupkg` and `releases.win.json`: update package and feed (use the exact generated names).

Upload all Velopack output files to the same stable release as the Mac DMG/appcast. The installed package ID is `MinutesDesktop`, keeping its install directory separate from `%LOCALAPPDATA%\Minutes`, where existing settings and models live. Do not change that ID after release. The setup/portable filenames are renamed for users; the feed retains its generated package filename.

The old `Minutes-<version>-win-x64.zip` is a raw publish archive for compatibility, not the recommended install path. Packages are currently unsigned at the Windows code-signing level; Velopack checks package hashes, but this is not publisher certificate verification.

Use a draft release until both platform files are present, then publish. Do not replace already published versioned packages; release a new version for a fix. Record CI results separately from testing on a real Windows PC. Test upgrade, restart, busy-state blocking, cancellation, network failure and preservation of workspace/model files on each supported platform.
