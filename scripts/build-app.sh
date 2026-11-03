#!/bin/bash
# Сборка AIRecorder.app, verify-session, mix-session, transcribe-session и diarize-session в app/build/.
# whisper.framework (E3) и dylib sherpa-onnx (E4) кладутся в AIRecorder.app/Contents/Frameworks
# и рядом с CLI. Иконка приложения и глифы меню-бара — в Contents/Resources (E4.2).
# Модели скачиваются отдельно: scripts/fetch-models.sh.
# Подпись ad-hoc (сертификата нет). macOS привязывает разрешения на микрофон и запись
# экрана к подписи, поэтому после каждой пересборки их может понадобиться выдать заново.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$(pwd)"
BUILD="$APP_DIR/build"
APP="$BUILD/AIRecorder.app"
SHERPA_LIBS=(libsherpa-onnx-c-api.dylib libonnxruntime.dylib)

./scripts/fetch-sherpa-onnx.sh   # dylib sherpa-onnx в Vendor/, не перекачиваются

swift build -c release --product AIRecorder
swift build -c release --product verify-session
swift build -c release --product mix-session
swift build -c release --product transcribe-session
swift build -c release --product diarize-session
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/AIRecorder" "$APP/Contents/MacOS/AIRecorder"
cp "$APP_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
# Новый номер сборки каждый раз,
# чтобы кеш значков macOS не держал старую иконку (ADR-006, «Измерения»).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$APP/Contents/Info.plist"
# Иконка приложения (E4.2): AppIcon.icns из AppIcon-1024.png, в репозитории только PNG
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$APP_DIR/Resources/Icons/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$APP_DIR/Resources/Icons/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# E5.1 (ADR-006 решение 18): Центр уведомлений новых macOS берёт значок из каталога ресурсов
# (Assets.car, CFBundleIconName), а не из .icns; без него в уведомлении пустая плашка.
# actool есть только с Xcode; без Xcode остаётся .icns.
if xcrun --find actool >/dev/null 2>&1; then
    XCASSETS="$BUILD/Assets.xcassets"
    rm -rf "$XCASSETS"
    mkdir -p "$XCASSETS/AppIcon.appiconset"
    echo '{"info":{"version":1,"author":"xcode"}}' > "$XCASSETS/Contents.json"
    images=""
    for size in 16 32 128 256 512; do
        cp "$ICONSET/icon_${size}x${size}.png" "$ICONSET/icon_${size}x${size}@2x.png" "$XCASSETS/AppIcon.appiconset/"
        images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"1x\",\"filename\":\"icon_${size}x${size}.png\"},"
        images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"2x\",\"filename\":\"icon_${size}x${size}@2x.png\"},"
    done
    echo "{\"images\":[${images%,}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$XCASSETS/AppIcon.appiconset/Contents.json"
    mkdir -p "$BUILD/assets-out"
    xcrun actool "$XCASSETS" --compile "$BUILD/assets-out" --platform macosx --minimum-deployment-target 13.3 \
        --app-icon AppIcon --output-partial-info-plist "$BUILD/assets-out/partial.plist" >/dev/null
    cp "$BUILD/assets-out/Assets.car" "$APP/Contents/Resources/Assets.car"
    rm -rf "$XCASSETS" "$BUILD/assets-out"
else
    echo "Внимание: нет actool (Xcode), Assets.car не собран: значок в уведомлениях может не показываться"
fi
rm -rf "$ICONSET"
# Глифы меню-бара (E4.2) грузятся через Bundle.main, не ресурсами SwiftPM: бандл ресурсов
# исполняемого таргета ложится в корень .app и ломает подпись
ditto "$APP_DIR/Resources/Icons/MenuBar" "$APP/Contents/Resources/MenuBar"
ditto "$BIN/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
for lib in "${SHERPA_LIBS[@]}"; do
    cp "$APP_DIR/Vendor/sherpa-onnx/lib/$lib" "$APP/Contents/Frameworks/$lib"
    cp "$APP_DIR/Vendor/sherpa-onnx/lib/$lib" "$BUILD/$lib"   # CLI ищут их рядом (@executable_path)
    codesign --force --sign - "$APP/Contents/Frameworks/$lib"
    codesign --force --sign - "$BUILD/$lib"
done
# rpath на Frameworks уже ставит SherpaEngine (Package.swift); добавляем, только если его нет
if ! otool -l "$APP/Contents/MacOS/AIRecorder" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AIRecorder"
fi
# rm перед cp: перезапись подписанного файла на месте (тот же inode) macOS убивает
# при запуске (SIGKILL, код 137) по закэшированной старой подписи
for tool in verify-session mix-session transcribe-session diarize-session; do
    rm -f "$BUILD/$tool"
    cp "$BIN/$tool" "$BUILD/$tool"
done
rm -rf "$BUILD/whisper.framework"
ditto "$BIN/whisper.framework" "$BUILD/whisper.framework"   # CLI ищут его рядом (@loader_path)
codesign --force --sign - "$BUILD/transcribe-session"
codesign --force --sign - "$BUILD/diarize-session"

codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - \
    --options runtime \
    --entitlements "$APP_DIR/Resources/AIRecorder.entitlements" \
    --identifier com.neridov.airecorder \
    "$APP"
codesign --verify --strict "$APP"
# Значок и путь .app заново в Launch Services: Центр уведомлений берёт значок оттуда
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Готово:"
echo "  $APP"
echo "  $BUILD/verify-session"
echo "  $BUILD/mix-session"
echo "  $BUILD/transcribe-session"
echo "  $BUILD/diarize-session"
