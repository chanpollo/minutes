param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
$tools = Join-Path $Destination 'tools'
$licenses = Join-Path $Destination 'licenses'
New-Item -ItemType Directory -Force $tools, $licenses | Out-Null
$work = Join-Path $env:RUNNER_TEMP 'minutes-tools'
New-Item -ItemType Directory -Force $work | Out-Null
$whisper = Join-Path $work 'whisper'
git clone https://github.com/ggml-org/whisper.cpp.git $whisper
if ($LASTEXITCODE) { throw 'whisper clone failed' }
git -C $whisper checkout --detach 4979e04f5dcaccb36057e059bbaed8a2f5288315
if ($LASTEXITCODE) { throw 'whisper checkout failed' }
cmake -S $whisper -B "$whisper/build" -A x64 -DGGML_NATIVE=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
if ($LASTEXITCODE) { throw 'whisper configure failed' }
cmake --build "$whisper/build" --config Release --target whisper-cli --parallel 2
if ($LASTEXITCODE) { throw 'whisper build failed' }
Get-ChildItem "$whisper/build" -Recurse -File | Where-Object { $_.Name -eq 'whisper-cli.exe' -or $_.Extension -eq '.dll' } | Copy-Item -Destination $tools -Force
Copy-Item "$whisper/LICENSE" "$licenses/whisper.cpp-LICENSE"
$archive = Join-Path $work 'sherpa.tar.bz2'
Invoke-WebRequest 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.15/sherpa-onnx-v1.12.15-win-x64-shared-no-tts.tar.bz2' -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'a13c8d0dcbdfc0d13495c81c8948ade823d5eef7f69f79a5d70e00ca88def4e3') { throw 'sherpa archive checksum mismatch' }
tar -xjf $archive -C $work
if ($LASTEXITCODE) { throw 'sherpa extraction failed' }
$sherpa = Join-Path $work 'sherpa-onnx-v1.12.15-win-x64-shared-no-tts'
$diarizer = Get-ChildItem $sherpa -Recurse -Filter 'sherpa-onnx-offline-speaker-diarization.exe' | Select-Object -First 1
if (-not $diarizer) { throw 'sherpa diarizer not found' }
Copy-Item $diarizer.FullName $tools
Get-ChildItem $sherpa -Recurse -Filter '*.dll' | Copy-Item -Destination $tools -Force
Invoke-WebRequest 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.12.15/LICENSE' -OutFile "$licenses/sherpa-onnx-LICENSE"
Invoke-WebRequest 'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.17.1/LICENSE' -OutFile "$licenses/onnxruntime-LICENSE"
Copy-Item windows/docs/THIRD-PARTY.md "$licenses/THIRD-PARTY.md"
if (-not (Test-Path "$tools/whisper-cli.exe")) { throw 'whisper-cli missing from bundle' }
