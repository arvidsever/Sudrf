#!/bin/bash
# GUI host for the existing synthetic XCTest fixture; never starts SudrfApp.
set -euo pipefail
rm -f /private/tmp/sudrf-340-gui-result.txt
rm -f /private/tmp/sudrf-340-hosted.png
cd "$(dirname "$0")/../../.."
swift test --filter VSRFMovementPresentationTests
BIN_DIR="$(swift build --show-bin-path)"
DEVELOPER="$(xcode-select -p)"
PLATFORM="$DEVELOPER/Platforms/MacOSX.platform/Developer"
APP="/private/tmp/SudrfVSRF340.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - <<'PYHOST'
from pathlib import Path
source = Path('Tests/SudrfAppTests/VSRFMovementPresentationTests.swift')
text = source.read_text().replace('#filePath', '"' + str(source.resolve()) + '"')
Path('/private/tmp/sudrf-340-gui.swift').write_text(text + Path('Docs/qa/issue-340/GUIHost.swift').read_text())
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
    /private/tmp/sudrf-340-gui.swift "${app_objects[@]}" "${objects[@]}" -lsqlite3 \
    -o "$APP/Contents/MacOS/VSRF340"
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
    cp -R "$bundle" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VSRF340</string>
<key>CFBundleIdentifier</key><string>ru.sudrf.qa.vsrf340</string>
<key>CFBundleName</key><string>Sudrf VSRF QA 340</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${SUDRF_VSRF340_LAUNCH:-0}" == "1" ]]; then
    open "$APP"
fi
printf '%s\n' 'Open /private/tmp/SudrfVSRF340.app, inspect its accessibility tree, then press Command-R to run GUI checks.'
