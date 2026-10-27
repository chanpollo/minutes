#!/bin/bash
# Installs whisper.cpp and downloads the speech and VAD models.
set -euo pipefail

MODELS="$HOME/Library/Application Support/Minutes/models"
HF=https://huggingface.co

command -v whisper-cli >/dev/null || brew install whisper-cpp
mkdir -p "$MODELS"

fetch() {
  local url=$1 out="$MODELS/$2"
  [ -s "$out" ] && { echo "have $2"; return; }
  curl -fL --retry 3 -o "$out.part" "$url"
  mv "$out.part" "$out"
  echo "got $2"
}

fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" ggml-large-v3-turbo-q5_0.bin
fetch "$HF/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" ggml-silero-v5.1.2.bin
