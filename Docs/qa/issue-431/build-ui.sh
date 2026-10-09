#!/bin/bash
# Build-only isolated QA app. It never launches and never reads the user store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
QA_BUILD="/private/tmp/sudrf-431/xcode-qa"
mkdir -p "$QA_BUILD"

python3 - "$ROOT" "$QA_BUILD" <<'PYCONFIG'
from pathlib import Path
import sys

root, build = map(Path, sys.argv[1:])
text = (root / "project.yml").read_text()
text = text.replace("    path: .", "    path: " + str(root))
text = text.replace("name: Sudrf\n", "name: Sudrf431QA\n", 1)
text = text.replace(
    "  Sudrf:\n    type: application", "  Sudrf431QA:\n    type: application", 1)
for model in (
    "model-captcha-numeric.mlmodelc",
    "model-captcha-numeric-specialist.mlmodelc",
    "model-captcha-fssp.mlmodelc",
):
    text = text.replace(
        "      - path: Tests/CaptchaSolverTests/Fixtures/" + model
        + "\n        type: folder\n        buildPhase: resources\n", "")
text = text.replace(
    "      - path: Tests/CaptchaSolverTests/Fixtures/model-captcha-fssp-eligibility.json\n"
    "        buildPhase: resources\n", "")
text = text.replace(
    "- path: Sources/SudrfApp",
    "- path: " + str(root / "Sources/SudrfApp")
    + "\n        excludes: [SudrfApp.swift]")
text = text.replace("- path: Assets.xcassets", "- path: " + str(root / "Assets.xcassets"))
text = text.replace("- path: Tests/", "- path: " + str(root / "Tests") + "/")
text = text.replace(
    "    dependencies:",
    "      - path: " + str(root / "Docs/qa/issue-431/GUIHost.swift")
    + "\n    dependencies:",
    1)
text = text.replace("path: Generated/", "path: " + str(build / "Generated") + "/")
text = text.replace(
    "PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.app",
    "PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue431")
text = text.replace("CFBundleName: Sudrf", "CFBundleName: Sudrf431QA")
text = text.replace("CFBundleDisplayName: Sudrf", "CFBundleDisplayName: Sudrf431QA")
text = text.replace("CFBundleURLName: ru.sudrf.app", "CFBundleURLName: ru.sudrf.qa.issue431")
text = text.replace("              - sudrf\n", "              - sudrf-qa-431\n")
text = text.replace("com.apple.security.network.client: true",
                    "com.apple.security.network.client: false")
text = text.replace("CODE_SIGN_STYLE: Automatic", "CODE_SIGN_STYLE: Manual")
text = text.replace(
    "  Sudrf:\n    build:\n      targets:\n        Sudrf: all",
    "  Sudrf431QA:\n    build:\n      targets:\n        Sudrf431QA: all")
(build / "project.yml").write_text(text)
PYCONFIG

(cd "$QA_BUILD" && xcodegen generate)
xcodebuild -project "$QA_BUILD/Sudrf431QA.xcodeproj" -scheme Sudrf431QA \
  -configuration Debug -derivedDataPath "$QA_BUILD/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build \
  > "$QA_BUILD/build.log" 2>&1
printf '%s\n' "$QA_BUILD/DerivedData/Build/Products/Debug/Sudrf431QA.app"
