#!/bin/bash
# GUI host for the existing synthetic XCTest fixture; never starts SudrfApp.
set -euo pipefail
cd "$(dirname "$0")/../../.."
swift test --filter CalendarMonthViewTests
BIN_DIR="$(swift build --show-bin-path)"
DEVELOPER="$(xcode-select -p)"
PLATFORM="$DEVELOPER/Platforms/MacOSX.platform/Developer"
APP="/private/tmp/SudrfCalendar351.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat Tests/SudrfAppTests/CalendarMonthViewTests.swift Docs/qa/issue-351/GUIHost.swift > /private/tmp/sudrf-351-gui.swift
app_objects=("$BIN_DIR"/ExecutableModules/SudrfApp-*-testable.o)
objects=()
for module in SudrfKit CaptchaSolver SwiftSoup ArgumentParser ArgumentParserToolInfo; do
    objects+=("$BIN_DIR/$module.o")
done
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos26.0" \
    -I "$BIN_DIR" -I "$PLATFORM/usr/lib" -L "$PLATFORM/usr/lib" \
    -F "$PLATFORM/Library/Frameworks" -framework XCTest \
    -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
    /private/tmp/sudrf-351-gui.swift "${app_objects[@]}" "${objects[@]}" -lsqlite3 \
    -o "$APP/Contents/MacOS/Calendar351"
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
    cp -R "$bundle" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Calendar351</string>
<key>CFBundleIdentifier</key><string>ru.sudrf.qa.calendar351</string>
<key>CFBundleName</key><string>Sudrf Calendar QA 351</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
open "$APP"
printf '%s\n' 'Inspect the Calendar351 accessibility tree, then press Command-R to run GUI checks.'
