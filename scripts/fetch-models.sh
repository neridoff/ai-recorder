#!/bin/bash
# Скачивает модели расшифровки (E3, ADR-004 решение 12) и разметки говорящих (E4, решения 24–25) в
# ~/Library/Application Support/AI Recorder/Models/ и проверяет SHA-256.
# Сеть нужна только этому скрипту: сама расшифровка работает без сети (NFR-01).
# Уже скачанные файлы с верной суммой не перекачиваются.
set -euo pipefail

DIR="${AIRECORDER_MODELS_DIR:-$HOME/Library/Application Support/AI Recorder/Models}"
mkdir -p "$DIR"

# имя файла, URL, SHA-256
MODELS=(
    "ggml-large-v3-turbo-q5_0.bin|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin|394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    "ggml-silero-v6.2.0.bin|https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin|2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
    "sherpa-onnx-pyannote-segmentation-3-0.onnx|https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx|220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"
    "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx|https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx|aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"
)

for entry in "${MODELS[@]}"; do
    IFS='|' read -r name url sha <<< "$entry"
    target="$DIR/$name"
    if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$sha" ]]; then
        echo "есть: $name"
        continue
    fi
    echo "скачиваю: $name"
    curl -fL --progress-bar -o "$target.part" "$url"
    actual="$(shasum -a 256 "$target.part" | cut -d' ' -f1)"
    if [[ "$actual" != "$sha" ]]; then
        rm -f "$target.part"
        echo "ошибка: SHA-256 $name не совпадает ($actual, ожидалось $sha)" >&2
        exit 1
    fi
    mv "$target.part" "$target"
done

echo "Модели в $DIR"
