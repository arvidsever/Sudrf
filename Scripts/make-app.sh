#!/bin/bash
#  make-app.sh — собирает SudrfApp.app (бандл) из Swift-пакета.
#
#  ЗАЧЕМ: «голый» исполняемый файл (`swift run SudrfApp` или схема в Xcode)
#  запускается без бандла и Info.plist — macOS 26 в этом случае рендерит окно
#  в режиме совместимости: без Liquid Glass, без стеклянного сайдбара,
#  с прямоугольными кнопками. Обёртка в .app включает новый дизайн.
#
#  Запуск:  bash Scripts/make-app.sh
#           bash Scripts/make-app.sh --ci   (noninteractive, no open, no codesign)
#  Результат: build/SudrfApp.app (и сразу открывается, кроме --ci) +
#  build/Sudrf-Alpha-0.39.33-build77.zip — универсальная сборка
#  (Apple Silicon + Intel), можно пересылать.

set -euo pipefail
cd "$(dirname "$0")/.."

# --ci: noninteractive. Не открываем .app, не подписываем (CI подписывает
# отдельно через свои entitlements; ad-hoc codesign тут — для local-разработки).
CI_MODE="0"
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE="1" ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="Sudrf"
RELEASE_CHANNEL="Alpha"
MARKETING_VERSION="0.40.4"
CURRENT_PROJECT_VERSION="84"
ARCHIVE="build/${APP_NAME}-${RELEASE_CHANNEL}-${MARKETING_VERSION}-build${CURRENT_PROJECT_VERSION}.zip"

ARCHES=(--arch arm64 --arch x86_64)
swift build -c release --product SudrfApp "${ARCHES[@]}"

APP="build/SudrfApp.app"
BIN="$(swift build -c release --product SudrfApp "${ARCHES[@]}" --show-bin-path)/SudrfApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SudrfApp"

# A5: CoreML model delivery. Модель должна быть уже в Fixtures/ —
# make-app.sh НЕ делает fetch (его делает CI build-test/package-app job
# или dev через Scripts/fetch-model.sh вручную). verify обязателен.
MODEL_FIXTURES_DIR="Tests/CaptchaSolverTests/Fixtures"
MODEL_MANIFEST="$MODEL_FIXTURES_DIR/MODEL_MANIFEST.sha256"
MODEL_DIR="$MODEL_FIXTURES_DIR/model-captcha-numeric.mlmodelc"
[[ -f "$MODEL_MANIFEST" ]] || {
    echo "manifest not found: $MODEL_MANIFEST (run Scripts/fetch-model.sh first)" >&2
    exit 1
}
[[ -d "$MODEL_DIR" ]] || {
    echo "model not found: $MODEL_DIR (run Scripts/fetch-model.sh first)" >&2
    exit 1
}
bash Scripts/verify-model.sh --model-dir "$MODEL_DIR" --manifest "$MODEL_MANIFEST"
cp -R "$MODEL_DIR" "$APP/Contents/Resources/"

# Иконка: собираем .icns из PNG ассет-каталога (iconutil есть в macOS).
ICONSET="build/AppIcon.iconset"
SRC="Assets.xcassets/AppIcon.appiconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
cp "$SRC/icon_16.png"     "$ICONSET/icon_16x16.png"
cp "$SRC/icon_16-2x.png"  "$ICONSET/icon_16x16@2x.png"
cp "$SRC/icon_32.png"     "$ICONSET/icon_32x32.png"
cp "$SRC/icon_32-2x.png"  "$ICONSET/icon_32x32@2x.png"
cp "$SRC/icon_128.png"    "$ICONSET/icon_128x128.png"
cp "$SRC/icon_128-2x.png" "$ICONSET/icon_128x128@2x.png"
cp "$SRC/icon_256.png"    "$ICONSET/icon_256x256.png"
cp "$SRC/icon_256-2x.png" "$ICONSET/icon_256x256@2x.png"
cp "$SRC/icon_512.png"    "$ICONSET/icon_512x512.png"
cp "$SRC/icon_512-2x.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>ru</string>
    <key>CFBundleExecutable</key>             <string>SudrfApp</string>
    <key>CFBundleIdentifier</key>             <string>ru.sudrf.app</string>
    <key>CFBundleName</key>                   <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>            <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>                <string>${CURRENT_PROJECT_VERSION}</string>
    <key>LSMinimumSystemVersion</key>         <string>26.0</string>
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>sudrf.ru</key>
            <dict>
                <key>NSIncludesSubdomains</key>              <true/>
                <key>NSExceptionMinimumTLSVersion</key>      <string>TLSv1.2</string>
                <key>NSExceptionRequiresForwardSecrecy</key> <false/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>msudrf.ru</key>
            <dict>
                <key>NSIncludesSubdomains</key>              <true/>
                <key>NSExceptionMinimumTLSVersion</key>      <string>TLSv1.2</string>
                <key>NSExceptionRequiresForwardSecrecy</key> <false/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>mos-gorsud.ru</key>
            <dict>
                <key>NSIncludesSubdomains</key>              <true/>
                <key>NSExceptionRequiresForwardSecrecy</key> <false/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

if [[ "$CI_MODE" != "1" ]]; then
    codesign --force --sign - "$APP"
fi

# Архив для передачи (ditto сохраняет подпись и атрибуты бандла).
ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "Готово: $APP"
echo "Для передачи: $ARCHIVE (получателю: macOS 26+, при первом запуске — xattr -cr SudrfApp.app или ПКМ → Открыть)"
if [[ "$CI_MODE" != "1" ]]; then
    open "$APP"
fi
