#!/bin/bash
# Generate and compile an isolated, native-sheet QA app. This script never launches it.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
QA="/private/tmp/sudrf-339-native-qa"
mkdir -p "$QA/Generated"
python3 - "$ROOT" "$QA" <<'PYCONFIG'
from pathlib import Path
import re
import sys

root, qa = (Path(arg).resolve() for arg in sys.argv[1:])
text = (root / "project.yml").read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one config anchor, found {count}")
    text = text.replace(old, new, 1)

replace_once("name: Sudrf\n", "name: Sudrf339QA\n", "project name")
replace_once("    path: .\n", f"    path: {root}\n", "Swift package path")
replace_once("  Sudrf:\n    type: application", "  Sudrf339QA:\n    type: application", "app target")
replace_once(
    "      - path: Sources/SudrfApp\n",
    f"      - path: {root / 'Sources/SudrfApp'}\n"
    "        excludes: [SudrfApp.swift, AppModel.swift]\n"
    f"      - path: {qa / 'AppModel+Issue339QA.swift'}\n"
    f"      - path: {root / 'Docs/qa/issue-339/GUIHost.swift'}\n",
    "QA source overlay",
)
replace_once(
    "      - path: Assets.xcassets\n",
    f"      - path: {root / 'Assets.xcassets'}\n",
    "source assets and local fixture",
)

# This native-sheet host has no need for CoreML or production model resources.
for model in (
    "model-captcha-numeric.mlmodelc",
    "model-captcha-numeric-specialist.mlmodelc",
    "model-captcha-fssp.mlmodelc",
):
    replace_once(
        f"      - path: Tests/CaptchaSolverTests/Fixtures/{model}\n"
        "        type: folder\n        buildPhase: resources\n",
        "",
        f"exclude model {model}",
    )
replace_once(
    "      - path: Tests/CaptchaSolverTests/Fixtures/model-captcha-fssp-eligibility.json\n"
    "        buildPhase: resources\n",
    "",
    "exclude model eligibility resource",
)

# Remove the production deep-link registration as a YAML node, not a loose text
# replacement that could leave part of the scheme array behind.
lines = text.splitlines(keepends=True)
url_node = "        CFBundleURLTypes:\n"
if lines.count(url_node) != 1:
    raise SystemExit("expected exactly one production URL type node")
start = lines.index(url_node)
end = start + 1
while end < len(lines):
    line = lines[end]
    if line.strip() and len(line) - len(line.lstrip(" ")) <= 8:
        break
    end += 1
text = "".join(lines[:start] + lines[end:])

for old, new, label in (
    ("CFBundleName: Sudrf\n", "CFBundleName: Sudrf339QA\n", "bundle name"),
    ("CFBundleDisplayName: Sudrf\n", "CFBundleDisplayName: Sudrf339QA\n", "display name"),
    ("PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.app\n", "PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue339\n", "bundle ID"),
):
    replace_once(old, new, label)

for pattern, replacement, label in (
    (r'(?m)^        MARKETING_VERSION: "[^"]+"\n', '        MARKETING_VERSION: "0.0.0"\n', "QA version"),
    (r'(?m)^        CURRENT_PROJECT_VERSION: "[^"]+"\n', '        CURRENT_PROJECT_VERSION: "1"\n', "QA build number"),
):
    text, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"{label}: expected one setting, found {count}")

for old, new, label in (
    ("com.apple.security.network.client: true\n", "com.apple.security.network.client: false\n", "network entitlement"),
    ("com.apple.security.files.user-selected.read-write: true\n", "com.apple.security.files.user-selected.read-write: false\n", "file access entitlement"),
    ("CODE_SIGN_STYLE: Automatic\n", "CODE_SIGN_STYLE: Manual\n", "signing style"),
):
    replace_once(old, new, label)

replace_once(
    "        SWIFT_STRICT_CONCURRENCY: complete\n",
    "        SWIFT_STRICT_CONCURRENCY: complete\n"
    "        ENABLE_TESTABILITY: YES\n",
    "internal test seams",
)

# Keep generated metadata inside the private QA directory.
text, generated_paths = re.subn(
    r"(?m)^([ \t]*path: )Generated/([^\n]+)$",
    lambda match: f"{match.group(1)}{qa / 'Generated' / match.group(2)}",
    text,
)
if generated_paths != 2:
    raise SystemExit(f"expected two generated metadata paths, found {generated_paths}")

replace_once(
    "  Sudrf:\n    build:\n      targets:\n        Sudrf: all\n",
    "  Sudrf339QA:\n    build:\n      targets:\n        Sudrf339QA: all\n",
    "QA scheme",
)

# Refuse broad or accidentally production-shaped projects before XcodeGen runs.
if "CFBundleURLTypes:" in text or "CFBundleURLSchemes:" in text or "CFBundleURLName:" in text:
    raise SystemExit("URL scheme registration remains in QA project config")
if "ru.sudrf.app" in text or "CFBundleURL" in text:
    raise SystemExit("production bundle/deep-link identity remains in QA project config")
target_block = text.split("targets:\n", 1)[1].split("\nschemes:\n", 1)[0]
targets = re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n    type:", target_block)
if targets != ["Sudrf339QA"]:
    raise SystemExit(f"unexpected app targets: {targets}")
scheme_block = text.split("schemes:\n", 1)[1]
schemes = re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n", scheme_block)
if schemes != ["Sudrf339QA"]:
    raise SystemExit(f"unexpected schemes: {schemes}")
if "PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue339\n" not in text:
    raise SystemExit("QA bundle ID setting missing")
if "Sudrf339QA" not in text:
    raise SystemExit("QA target identity missing")

for match in re.finditer(r"(?m)^\s+path:\s+(\S+)\s*$", text):
    path = Path(match.group(1))
    if not path.is_absolute():
        raise SystemExit(f"relative path not allowed in generated project: {path}")

source = (root / "Sources/SudrfApp/AppModel.swift").read_text()
expected_sha = "6124b5eca0a9b4e848efb0d3bd6836c0587425471e98abea03a201f8593d1f13"
import hashlib
if hashlib.sha256(source.encode()).hexdigest() != expected_sha:
    raise SystemExit("AppModel changed: review QA overlay anchors before rebuilding")
original_sheet = (root / "Sources/SudrfApp/DirectCaseLinkSheet.swift").read_bytes()
if hashlib.sha256(original_sheet).hexdigest() != "4e96f1c8ab110397d79523f8b490314947398aa1fda4a901aacd07da2bb20d44":
    raise SystemExit("DirectCaseLinkSheet changed: review native QA source before rebuilding")
transforms = [
    ("    let client = SudrfClient()", "    let client = Issue339QAFixtures.client"),
    ("self.directCaseLinkResolver = DirectCaseLinkResolver(client: client)",
     "self.directCaseLinkResolver = Issue339QAFixtures.resolver"),
    ("let originResolver = CaseOriginResolver(client: client)",
     "let originResolver = CaseOriginResolver(client: client, "
     "districtResolver: DistrictCourtResolver(client: client, cacheURL: nil), "
     "magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil))"),
    ("        SudrfIntentRuntime.shared.install(self)",
     "        // QA: no App Intent runtime registration."),
]
for old, new in transforms:
    if source.count(old) != 1:
        raise SystemExit(f"expected one overlay anchor: {old}")
    source = source.replace(old, new, 1)
badge = "FeedNotifier.shared.setBadge(newBadge)"
if source.count(badge) != 2:
    raise SystemExit("expected two Dock badge publication sites")
source = source.replace(badge, "// QA: no Dock badge publication.")
notification_hook = """        FeedNotifier.shared.onOpen = { [weak self] key in
            NSApp.activate(ignoringOtherApps: true)
            self?.openCase(key: key)
        }
"""
if source.count(notification_hook) != 1:
    raise SystemExit("expected one notification open hook")
source = source.replace(notification_hook, "        // QA: no notification open hook.\n", 1)
(qa / "AppModel+Issue339QA.swift").write_text(source)
entrypoints = [path for path in (root / "Sources/SudrfApp").rglob("*.swift")
               if path.name not in {"SudrfApp.swift", "AppModel.swift"}
               and re.search(r"(?m)^\s*@main\b", path.read_text())]
if entrypoints or len(re.findall(r"(?m)^\s*@main\b", (root / "Docs/qa/issue-339/GUIHost.swift").read_text())) != 1:
    raise SystemExit("QA project must contain exactly one QA entrypoint")
if re.search(r"(?m)^\s*@main\b", source):
    raise SystemExit("AppModel overlay must not have an entrypoint")

(qa / "project.yml").write_text(text)
PYCONFIG

(cd "$QA" && xcodegen generate)
xcodebuild -project "$QA/Sudrf339QA.xcodeproj" \
  -scheme Sudrf339QA -configuration Debug \
  -derivedDataPath "$QA/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ENABLE_TESTABILITY=YES build \
  > "$QA/xcodebuild.log" 2>&1

APP="$QA/DerivedData/Build/Products/Debug/Sudrf339QA.app"
python3 - "$APP/Contents/Info.plist" "$QA/Generated/Sudrf.entitlements" <<'PYPLIST'
import plistlib
import sys
from pathlib import Path
info_path, entitlements_path = map(Path, sys.argv[1:])
info = plistlib.loads(info_path.read_bytes())
assert info.get("CFBundleIdentifier") == "ru.sudrf.qa.issue339", info.get("CFBundleIdentifier")
assert "CFBundleURLTypes" not in info, "QA app must not register URL schemes"
assert "CFBundleURLSchemes" not in info, "QA app must not register URL schemes"
entitlements = plistlib.loads(entitlements_path.read_bytes())
assert entitlements.get("com.apple.security.network.client") is False, entitlements
assert entitlements.get("com.apple.security.files.user-selected.read-write") is False, entitlements
PYPLIST

codesign --verify --strict "$APP"
codesign -d --entitlements :- "$APP" > "$QA/signed-entitlements.plist" 2> "$QA/signature.log"
python3 - "$QA/signed-entitlements.plist" <<'PYSIGNED'
import plistlib
import sys
from pathlib import Path
entitlements = plistlib.loads(Path(sys.argv[1]).read_bytes())
assert entitlements.get("com.apple.security.app-sandbox") is True
assert entitlements.get("com.apple.security.network.client") is False
assert entitlements.get("com.apple.security.files.user-selected.read-write") is False
PYSIGNED

printf '%s\n' "Build passed: $APP" "Bundle ID: ru.sudrf.qa.issue339" "Network entitlement: false" "No launch performed."
