#!/bin/bash
# GUI host for the existing synthetic XCTest fixture; never starts SudrfApp.
set -euo pipefail
rm -f /private/tmp/sudrf-128-gui-result.txt
rm -f /private/tmp/sudrf-128-hosted.png
cd "$(dirname "$0")/../../.."
swift test --scratch-path /private/tmp/sudrf128-scratch --filter Issue128DeadlineVisualTests
BIN_DIR="$(swift build --scratch-path /private/tmp/sudrf128-scratch --show-bin-path)"
DEVELOPER="$(xcode-select -p)"
PLATFORM="$DEVELOPER/Platforms/MacOSX.platform/Developer"
APP="/private/tmp/SudrfDeadline128.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - <<'PYHOST'
from pathlib import Path
source = Path('Tests/SudrfAppTests/Issue128DeadlineVisualTests.swift')
text = source.read_text().replace('#filePath', '"' + str(source.resolve()) + '"')
Path('/private/tmp/sudrf-128-gui.swift').write_text(text + Path('Docs/qa/issue-128/GUIHost.swift').read_text())
PYHOST
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
    /private/tmp/sudrf-128-gui.swift "${app_objects[@]}" "${objects[@]}" -lsqlite3 \
    -o "$APP/Contents/MacOS/Deadline128"
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
    cp -R "$bundle" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Deadline128</string>
<key>CFBundleIdentifier</key><string>ru.sudrf.qa.deadline128</string>
<key>CFBundleName</key><string>Sudrf Deadline QA 128</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${SUDRF_DEADLINE128_LAUNCH:-0}" == "1" ]]; then
    open "$APP"
fi
printf '%s\n' 'Launch with SUDRF_DEADLINE128_QA_OUTPUT as documented in README.md, then press Command-R. A skipped acceptance test is a failure.'
