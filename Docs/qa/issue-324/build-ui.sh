#!/bin/bash
# Build-only isolated QA app. It never launches and never points at the user store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
QA_BUILD="/private/tmp/sudrf-324/xcode-qa"
mkdir -p "$QA_BUILD"
python3 - "$ROOT" "$QA_BUILD" <<'PYCONFIG'
from pathlib import Path
import re
import sys

root, build = map(Path, sys.argv[1:])
text = (root / "project.yml").read_text()
text = text.replace("    path: .", "    path: " + str(root))
text = text.replace(
    "name: Sudrf\n", "name: Sudrf324QA\n", 1)
text = text.replace(
    "  Sudrf:\n    type: application", "  Sudrf324QA:\n    type: application", 1)
for model in (
    "model-captcha-numeric.mlmodelc",
    "model-captcha-numeric-specialist.mlmodelc",
    "model-captcha-fssp.mlmodelc",
):
    text = text.replace(
        "      - path: Tests/CaptchaSolverTests/Fixtures/" + model
        + "\n        type: folder\n        buildPhase: resources\n", "")
text = text.replace(
    "- path: Sources/SudrfApp",
    "- path: " + str(root / "Sources/SudrfApp") + "\n        excludes: [SudrfApp.swift]")
text = text.replace("- path: Assets.xcassets", "- path: " + str(root / "Assets.xcassets"))
text = text.replace("- path: Tests/", "- path: " + str(root / "Tests") + "/")
text = text.replace(
    "    dependencies:",
    "      - path: " + str(root / "Docs/qa/issue-324/GUIHost.swift") + "\n    dependencies:",
    1)
text = text.replace("path: Generated/", "path: " + str(build / "Generated") + "/")
for key, value in (
    ("CFBundleName", "Sudrf324QA"),
    ("CFBundleDisplayName", "Sudrf324QA"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "ru.sudrf.qa.issue324"),
    ("PRODUCT_NAME", "Sudrf324QA"),
    ("SUDRF_DISPLAY_NAME", "Sudrf324QA"),
    ("SUDRF_URL_SCHEME", "sudrf-qa-324"),
):
    text = re.sub(r"(?m)^([ \t]*" + re.escape(key) + r":)[^\n]*$",
                  r"\1 " + value, text)
text = re.sub(r"(?m)^([ \t]*-[ \t]*CFBundleURLName:)[^\n]*$",
              r"\1 ru.sudrf.qa.issue324", text)
text = re.sub(
    r"(?m)^([ \t]*CFBundleURLSchemes:\n[ \t]*-[ \t]*).+$",
    r"\1sudrf-qa-324", text)
text = text.replace("CODE_SIGN_STYLE: Automatic", "CODE_SIGN_STYLE: Manual")
text = text.replace(
    "  Sudrf:\n    build:\n      targets:\n        Sudrf: all",
    "  Sudrf324QA:\n    build:\n      targets:\n        Sudrf324QA: all")
(build / "project.yml").write_text(text)
PYCONFIG
(cd "$QA_BUILD" && xcodegen generate)
xcodebuild -project "$QA_BUILD/Sudrf324QA.xcodeproj" -scheme Sudrf324QA \
  -configuration Debug -derivedDataPath "$QA_BUILD/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build \
  > "$QA_BUILD/build.log" 2>&1
printf '%s\n' "$QA_BUILD/DerivedData/Build/Products/Debug/Sudrf324QA.app"
