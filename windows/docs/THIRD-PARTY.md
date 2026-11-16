# Third-party components

The portable ZIP includes .NET 8 and Windows App SDK runtime files under their upstream redistribution terms, NAudio 2.2.1 (MIT), whisper.cpp v1.8.2 / commit `4979e04f5dcaccb36057e059bbaed8a2f5288315` (MIT), sherpa-onnx v1.12.15 (Apache-2.0), and its ONNX Runtime dependency (MIT). The workflow copies speech engine license texts into licenses/. Runtime NuGet notices must be retained with the distribution.

whisper.cpp is compiled for a baseline x64 CPU, without native/AVX/AVX2/FMA/F16C assumptions. sherpa-onnx's official shared no-TTS archive is pinned by SHA-256 in Bundle-Tools.ps1. Models download separately from the exact Mac ModelStore sources, checked by SHA-256. Model licenses are those of their publishers; no model weights or OAuth clients are committed.

Upstreams: https://github.com/ggml-org/whisper.cpp, https://github.com/k2-fsa/sherpa-onnx, https://github.com/microsoft/onnxruntime, https://github.com/naudio/NAudio.
