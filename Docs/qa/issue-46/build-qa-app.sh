#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../../.."
QA_BUILD_ROOT="/private/tmp/sudrf-46-qa-build"
mkdir -p "$QA_BUILD_ROOT"
python3 - <<'PYQA'
from pathlib import Path
root = Path.cwd()
out = Path('/private/tmp/sudrf-46-qa-build')
spec = f"""name: SudrfQA46
options:
  deploymentTarget:
    macOS: '26.0'
packages:
  SudrfKit:
    path: '{root}'
targets:
  SudrfQA46:
    type: application
    platform: macOS
    sources:
      - path: '{root}/Sources/SudrfApp'
        excludes: [SudrfApp.swift]
      - path: '{root}/Docs/qa/issue-46/QAApp.swift'
      - path: '{root}/Assets.xcassets'
    dependencies:
      - package: SudrfKit
        product: SudrfKit
      - package: SudrfKit
        product: CaptchaSolver
    info:
      path: '{out}/QA46-Info.plist'
      properties:
        CFBundleName: SudrfQA46
        CFBundleDisplayName: Sudrf QA46
        CFBundleShortVersionString: '1.0'
        CFBundleVersion: '1'
        NSHumanReadableCopyright: '© 2026 Воробьёв Виктор Викторович'
        LSMinimumSystemVersion: '26.0'
        NSPrincipalClass: NSApplication
        NSHighResolutionCapable: true
        CFBundleDevelopmentRegion: ru
    entitlements:
      path: '{out}/QA46.entitlements'
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
        com.apple.security.files.user-selected.read-write: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue46
        MACOSX_DEPLOYMENT_TARGET: '26.0'
        SWIFT_VERSION: '6.0'
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG SUDRF_QA_46
        ENABLE_TESTABILITY: YES
        CODE_SIGNING_ALLOWED: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
"""
(out/'project.yml').write_text(spec)
PYQA
xcodegen generate --spec "$QA_BUILD_ROOT/project.yml" --project "$QA_BUILD_ROOT"
xcodebuild -project "$QA_BUILD_ROOT/SudrfQA46.xcodeproj" -scheme SudrfQA46 \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$QA_BUILD_ROOT/derived" \
    CODE_SIGNING_ALLOWED=NO build
QA_APP="$QA_BUILD_ROOT/derived/Build/Products/Debug/SudrfQA46.app"
codesign --force --sign - --entitlements "$QA_BUILD_ROOT/QA46.entitlements" "$QA_APP"
codesign --verify --strict "$QA_APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$QA_APP/Contents/Info.plist"
printf '%s\n' 'Built and ad-hoc signed own sandbox QA46 app; launch remains a separate reviewed step.'
