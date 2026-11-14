#!/bin/bash
# Installs whisper.cpp and the sherpa-onnx speaker diarizer, and downloads the speech, VAD and speaker models.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Minutes"
MODELS="$SUPPORT/models"
TOOLS="$SUPPORT/tools"
HF=https://huggingface.co
SHERPA=https://github.com/k2-fsa/sherpa-onnx/releases/download
SHERPA_BUILD=sherpa-onnx-v2.0.1-osx-universal2-shared-no-tts

command -v whisper-cli >/dev/null || brew install whisper-cpp
mkdir -p "$MODELS" "$TOOLS"

fetch() {
  local url=$1 out="$MODELS/$2"
  [ -s "$out" ] && { echo "have $2"; return; }
  curl -fL --retry 3 -o "$out.part" "$url"
  mv "$out.part" "$out"
  echo "got $2"
}

# Downloads a .tar.bz2 and extracts the listed members into $dest; skipped when $check exists.
unpack() {
  local url=$1 dest=$2 check=$3 strip=$4; shift 4
  [ -s "$dest/$check" ] && { echo "have $check"; return; }
  local tmp
  tmp=$(mktemp -d)
  curl -fL --retry 3 -o "$tmp/archive.tar.bz2" "$url"
  mkdir -p "$tmp/out"
  tar -xjf "$tmp/archive.tar.bz2" -C "$tmp/out" --strip-components "$strip" "$@"
  mkdir -p "$dest"
  cp -R "$tmp/out/" "$dest/"
  rm -rf "$tmp"
  echo "got $check"
}

fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" ggml-large-v3-turbo-q5_0.bin
fetch "$HF/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" ggml-silero-v5.1.2.bin

unpack "$SHERPA/v2.0.1/$SHERPA_BUILD.tar.bz2" "$TOOLS/sherpa-onnx" bin/sherpa-onnx-offline-speaker-diarization 1 \
  "$SHERPA_BUILD/bin/sherpa-onnx-offline-speaker-diarization" "$SHERPA_BUILD/lib/libonnxruntime.dylib"
unpack "$SHERPA/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" "$MODELS" \
  sherpa-onnx-pyannote-segmentation-3-0/model.onnx 0
fetch "$SHERPA/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx" \
  3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
