#!/bin/bash
#  make-app.sh — собирает SudrfApp.app (бандл) из Swift-пакета.
#
#  ЗАЧЕМ: «голый» исполняемый файл (`swift run SudrfApp` или схема в Xcode)
#  запускается без бандла и Info.plist — macOS 26 в этом случае рендерит окно
#  в режиме совместимости: без Liquid Glass, без стеклянного сайдбара,
#  с прямоугольными кнопками. Обёртка в .app включает новый дизайн.
#
#  Запуск:  bash Scripts/make-app.sh
#  Результат: build/SudrfApp.app (и сразу открывается) + build/Sudrf.zip —
#  универсальная сборка (Apple Silicon + Intel), можно пересылать.

set -euo pipefail
cd "$(dirname "$0")/.."

ARCHES=(--arch arm64 --arch x86_64)
swift build -c release --product SudrfApp "${ARCHES[@]}"

APP="build/SudrfApp.app"
BIN="$(swift build -c release --product SudrfApp "${ARCHES[@]}" --show-bin-path)/SudrfApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SudrfApp"

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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>ru</string>
    <key>CFBundleExecutable</key>             <string>SudrfApp</string>
    <key>CFBundleIdentifier</key>             <string>ru.sudrf.kit.app</string>
    <key>CFBundleName</key>                   <string>Sudrf</string>
    <key>CFBundleDisplayName</key>            <string>Sudrf</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>37.0</string>
    <key>CFBundleVersion</key>                <string>37</string>
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
                <key>NSExceptionMinimumTLSVersion</key>      <string>TLSv1.0</string>
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

codesign --force --sign - "$APP"

# Архив для передачи (ditto сохраняет подпись и атрибуты бандла).
ditto -c -k --keepParent "$APP" "build/Sudrf.zip"

echo "Готово: $APP"
echo "Для передачи: build/Sudrf.zip (получателю: macOS 26+, при первом запуске — xattr -cr SudrfApp.app или ПКМ → Открыть)"
open "$APP"
