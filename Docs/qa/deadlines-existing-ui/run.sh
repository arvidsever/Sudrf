#!/bin/bash
# GUI host for the existing synthetic XCTest fixture; never starts SudrfApp.
set -euo pipefail
rm -f /private/tmp/sudrf-existing-ui-gui-result.txt
rm -f /private/tmp/sudrf-existing-ui-hosted.png
cd "$(dirname "$0")/../../.."
swift test --scratch-path /private/tmp/sudrf372-scratch --filter DeadlineExistingUITests
BIN_DIR="$(swift build --scratch-path /private/tmp/sudrf372-scratch --show-bin-path)"
DEVELOPER="$(xcode-select -p)"
PLATFORM="$DEVELOPER/Platforms/MacOSX.platform/Developer"
APP="/private/tmp/SudrfDeadlineExistingUI.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - <<'PYHOST'
from pathlib import Path
parts = []
for name in ['Issue222VisualTests.swift', 'DeadlineExistingUITests.swift']:
    source = Path('Tests/SudrfAppTests') / name
    parts.append(source.read_text().replace('#filePath', '"' + str(source.resolve()) + '"'))
loader = Path('Tests/SudrfAppTests/Issue372CassationDeadlineTests.swift').read_text()
loader = loader[loader.index('enum Issue372CassationFixtures'):loader.index('final class Issue372CassationDeadlineTests')]
start = loader.index('        let url = try XCTUnwrap(Bundle.module.url(')
end = loader.index('        let entries', start)
fixture = Path('Tests/SudrfAppTests/Fixtures/issue372_movement_examples.json').resolve()
loader = loader[:start] + '        let url = URL(fileURLWithPath: "' + str(fixture) + '")\n' + loader[end:]
parts.append(loader)
parts.append(Path('Docs/qa/deadlines-existing-ui/GUIHost.swift').read_text())
Path('/private/tmp/sudrf-existing-ui-gui.swift').write_text('\n'.join(parts))
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
    /private/tmp/sudrf-existing-ui-gui.swift "${app_objects[@]}" "${objects[@]}" -lsqlite3 \
    -o "$APP/Contents/MacOS/DeadlineExistingUI"
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
    cp -R "$bundle" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DeadlineExistingUI</string>
<key>CFBundleIdentifier</key><string>ru.sudrf.qa.deadlines-existing-ui</string>
<key>CFBundleName</key><string>Sudrf Existing UI QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${SUDRF_DEADLINE_EXISTING_UI_LAUNCH:-0}" == "1" ]]; then
    open "$APP"
fi
printf '%s\n' 'Launch with SUDRF_DEADLINE_EXISTING_UI_OUTPUT as documented in README.md. Checks run automatically; a skipped acceptance test is a failure.'
