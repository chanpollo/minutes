param([Parameter(Mandatory)][string]$Vpk)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'minutes-updater-smoke'
$publish = Join-Path $root 'publish'
$releases = Join-Path $root 'releases'
$installed = Join-Path $root 'installed'
$result = Join-Path $root 'result.txt'
dotnet publish windows/Minutes.UpdateSmoke/Minutes.UpdateSmoke.csproj -c Release -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Smoke host publish failed' }
& $Vpk pack --packId MinutesUpdateSmoke --packVersion 1.0.0 --packDir $publish --mainExe Minutes.UpdateSmoke.exe --outputDir $releases
if ($LASTEXITCODE -ne 0) { throw 'Baseline package failed' }
Expand-Archive (Join-Path $releases 'MinutesUpdateSmoke-win-Portable.zip') $installed
& $Vpk pack --packId MinutesUpdateSmoke --packVersion 1.1.0 --packDir $publish --mainExe Minutes.UpdateSmoke.exe --outputDir $releases
if ($LASTEXITCODE -ne 0) { throw 'Upgrade package failed' }
Start-Process (Join-Path $installed 'current/Minutes.UpdateSmoke.exe') -ArgumentList @('update', $releases, $result)
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and !(Test-Path $result) -and !(Test-Path "$result.error")) { Start-Sleep -Seconds 1 }
if (Test-Path "$result.error") { throw (Get-Content "$result.error" -Raw) }
if (!(Test-Path $result)) { throw 'Update and relaunch timed out' }
Get-Content $result
