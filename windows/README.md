# Minutes for Windows

.NET 8 / WinUI 3 port of macOS 0.7.0. **Incomplete preview; full feature parity is not yet achieved.** See [PARITY.md](docs/PARITY.md) for implemented and missing behavior, and [TESTING.md](docs/TESTING.md) before trying the unsigned app.

## Portable tests (macOS, Linux, Windows)

Install a .NET 8 SDK, then:

```sh
cd windows
dotnet test Minutes.Core.Tests/Minutes.Core.Tests.csproj
```

Only Minutes.Core and its tests are platform independent. Do not build the WinUI project on macOS.

## Build on Windows x64

Install .NET 8 SDK and Visual Studio 2022's Windows application development workload with Windows 10/11 SDK. Then:

```powershell
dotnet restore windows/Minutes.App/Minutes.App.csproj -p:Platform=x64
dotnet build windows/Minutes.App/Minutes.App.csproj -c Release -p:Platform=x64
dotnet publish windows/Minutes.App/Minutes.App.csproj -c Release -p:Platform=x64 -o windows/artifacts/Minutes
```

GitHub Actions runs portable tests, compiles WinUI and publishes an unsigned self-contained x64 ZIP. There is no signing, tag, release or main-branch push. Run the full extracted folder. Models are not bundled: Download Speech Models in Settings installs the Mac model URLs and hashes under `%LOCALAPPDATA%\Minutes\models`.

A Voice recording currently uses the default microphone and **all system audio**. Screen capture, process-scoped audio and automatic meeting detection are pending. The app explicitly asks before substituting Voice for the Screen preference. Do not use this preview for confidential or important meetings until real-PC validation and the open privacy/recovery gates are complete.

The editable workspace format matches the Mac (meta.json, transcript.md, summary.md, notes.md, comments, revisions, attachments, frames, briefing). A folder-sync export is deliberately a document export and excludes meta.json, just as the Mac does. Share an editable workspace by selecting the same synced workspace folder on both platforms.
