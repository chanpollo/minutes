# Minutes 1.1.0 — Update from inside the app

## Install this release once

| Platform | Download | Installation |
|---|---|---|
| macOS 14.2+, Apple silicon and Intel | [Minutes-1.1.0.dmg](https://github.com/chanpollo/minutes/releases/download/v1.1.0/Minutes-1.1.0.dmg) | Open the DMG and drag Minutes to Applications. |
| Windows 10/11 x64 | [Minutes-win-Setup.exe](https://github.com/chanpollo/minutes/releases/download/v1.1.0/Minutes-win-Setup.exe) | Run Setup, then open Minutes from its shortcut. |
| Windows portable | [Minutes-win-Portable.zip](https://github.com/chanpollo/minutes/releases/download/v1.1.0/Minutes-win-Portable.zip) | Extract the whole archive and keep its files together. |

Users on 1.0.0 must quit the old app and install this release manually once. Recording/transcription need no AI account; speech models download on first launch. Summary providers are installed separately. Meeting workspaces and models remain outside the app installation.

## What's new

- Mac: **Minutes → Check for Updates…**, also available in the menu bar. Sparkle downloads and verifies the signed update, installs it and relaunches Minutes.
- Windows: **Check for Updates → Update & Restart** with Velopack, plus a Setup installer and an update-enabled portable package.
- Updates are user-initiated. Recording and processing must finish before updating. The app does not silently install updates at startup.

The `.nupkg`, `releases.win.json` and `appcast.xml` assets are updater files, not initial installers.

## First-launch warnings

Mac: the app uses an Apple Development signature and is **not notarised**. If blocked, verify the download came from this repository, then use **System Settings → Privacy & Security → Open Anyway**. Do not bypass a warning that the app will damage your computer. Managed Macs may need IT approval.

Windows: the installer and executable are **unsigned**, so Windows may display a security warning; managed PCs may need IT approval. Windows ARM and 32-bit packages are not provided.

## Validation and limits

- Mac unit tests: 14 passed, 0 failed (baseline: 13 passed). Includes a regression check that installation defers during active work and resumes when idle.
- Windows portable core tests: 147 passed, 0 failed (same counts as baseline); WinUI build and Velopack packaging passed on Windows CI.
- Mac isolated integration: an older app copy was updated to build 21; the installed app signature verified. A valid EdDSA archive was accepted, a tampered archive rejected, and the updated copy reported no newer version.
- Windows independent updater fixture: baseline package → downloaded upgrade → restarted into 1.1.0 → no repeat update, passed on Windows runner. This exercises Velopack's update engine, separately from the full Minutes UI.
- Real-device checks of the full Windows app's recording, calendar, sign-in, sync, updater UI and busy-state interactions remain outstanding. Mac's normal update UI/relaunch and busy-state interactions have not been manually exercised; the busy-state delegate is covered by an automated regression test and the isolated test used an automated test driver.

Mac package source: f79af12 (build 21). Windows package source: f9abb9b, [build and updater validation](https://github.com/chanpollo/minutes/actions/runs/44007959645). Additional updater smoke tests: [run](https://github.com/chanpollo/minutes/actions/runs/44006834969). Windows uses the MinutesDesktop package ID so installation is separate from existing settings/models in LocalAppData/Minutes. The Mac runtime source is unchanged by the later Windows fixes.

[Installation guide](https://github.com/chanpollo/minutes#install) · [Update operations](https://github.com/chanpollo/minutes/blob/main/docs/UPDATES.md) · [Windows feature gaps](https://github.com/chanpollo/minutes/blob/main/windows/docs/PARITY.md)
