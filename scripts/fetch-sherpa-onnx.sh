#!/bin/bash
# Скачивает готовые библиотеки sherpa-onnx (E4, ADR-004 решение 23) в app/Vendor/sherpa-onnx/:
# lib/libsherpa-onnx-c-api.dylib, lib/libonnxruntime.dylib и include/c-api.h, с проверкой SHA-256.
# Нужен до первой `swift build`: модуль CSherpaOnnx ссылается на эти файлы.
# Уже скачанные файлы с верной суммой не перекачиваются.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="v1.13.8"
DIR="Vendor/sherpa-onnx"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION"
ARCHIVE="sherpa-onnx-$VERSION-osx-arm64-shared-lib.tar.bz2"
ARCHIVE_SHA="ae77050cdae565496059d96f5ab33d77b397a0864282a4e4a26e3b3b3effb948"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VERSION/sherpa-onnx/c-api/c-api.h"
HEADER_SHA="2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch() {   # url, файл, sha
    if [[ -f "$2" ]] && [[ "$(sha "$2")" == "$3" ]]; then return; fi
    echo "скачиваю: $(basename "$2")"
    curl -fL --progress-bar -o "$2.part" "$1"
    local actual
    actual="$(sha "$2.part")"
    if [[ "$actual" != "$3" ]]; then
        rm -f "$2.part"
        echo "ошибка: SHA-256 $(basename "$2") не совпадает ($actual, ожидалось $3)" >&2
        exit 1
    fi
    mv "$2.part" "$2"
}

mkdir -p "$DIR/lib" "$DIR/include" "$DIR/download"
fetch "$BASE/$ARCHIVE" "$DIR/download/$ARCHIVE" "$ARCHIVE_SHA"
fetch "$HEADER_URL" "$DIR/include/c-api.h" "$HEADER_SHA"

if [[ ! -f "$DIR/lib/.version" ]] || [[ "$(cat "$DIR/lib/.version")" != "$ARCHIVE_SHA" ]]; then
    tmp="$(mktemp -d)"
    tar xjf "$DIR/download/$ARCHIVE" -C "$tmp"
    for lib in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
        cp "$tmp/sherpa-onnx-$VERSION-osx-arm64-shared-lib/lib/$lib" "$DIR/lib/$lib"
    done
    rm -rf "$tmp"
    echo "$ARCHIVE_SHA" > "$DIR/lib/.version"
fi

echo "sherpa-onnx $VERSION в $DIR"
