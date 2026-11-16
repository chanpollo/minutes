# Minutes for Windows

.NET 8 / WinUI 3 port of macOS 0.7.0. Windows version: **1.0.0**. Full feature parity is not yet achieved. See [PARITY.md](docs/PARITY.md) for implemented and missing behavior, and [TESTING.md](docs/TESTING.md) before trying the unsigned app.

## Install the download

Download [Minutes-1.0.0-win-x64.zip](https://github.com/chanpollo/minutes/releases/download/v1.0.0/Minutes-1.0.0-win-x64.zip), choose **Extract All**, and run **Minutes.App.exe** from the extracted folder. Keep all files together. No .NET SDK or Visual Studio is needed for the published ZIP. The app is unsigned and speech models download on first launch.

See the [installation guide](../README.md#install) for requirements, first-run setup and summary providers.

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
cd windows
msbuild Minutes.App/Minutes.App.csproj -t:Restore -p:Platform=x64 -p:Configuration=Release
msbuild Minutes.App/Minutes.App.csproj -t:Build -p:Platform=x64 -p:Configuration=Release
msbuild Minutes.App/Minutes.App.csproj -t:Publish -p:Platform=x64 -p:Configuration=Release -p:PublishDir=../artifacts/Minutes/
```

GitHub Actions runs portable tests, compiles WinUI and publishes an unsigned self-contained x64 ZIP. There is no signing, tag, release or main-branch push. Run the full extracted folder. Models are not bundled: first launch downloads them, and Download Speech Models in Settings retries installation of the Mac model URLs and hashes under `%LOCALAPPDATA%\Minutes\models`.

Voice records the microphone and process-scoped call audio when a detected app is available, with whole-system audio as fallback. Screen adds WGC H.264 video, finalized with mixed AAC audio. The tray offers both modes and the Record? card remembers a mode per app. These paths compile on Windows CI but have not been exercised on a real PC. Full parity remains incomplete: see the explicit implementation gates in PARITY.md, including WYSIWYG notes, AEC fallback for devices without a driver AEC effect and remaining sidebar/menu behavior. Recording can run while earlier meetings wait for serialized processing; that concurrency still needs real-PC validation.

The editable workspace format matches the Mac (meta.json, transcript.md, summary.md, notes.md, comments, revisions, attachments, frames, briefing). A folder-sync export is deliberately a document export and excludes meta.json, just as the Mac does. Share an editable workspace by selecting the same synced workspace folder on both platforms.
