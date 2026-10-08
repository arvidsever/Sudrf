#!/bin/bash
# Build only; never launches an app. Isolated QA bundle and in-memory store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
QA_BUILD="/private/tmp/sudrf-414/xcode-qa"
mkdir -p "$QA_BUILD"
python3 - "$ROOT" "$QA_BUILD" <<'PYCONFIG'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
text = (root / 'project.yml').read_text()
text = text.replace('    path: .', '    path: ' + str(root))
text = text.replace('- path: Sources/SudrfApp', '- path: ' + str(root / 'Sources/SudrfApp') + '\n        excludes: [SudrfApp.swift]')
text = text.replace('- path: Assets.xcassets', '- path: ' + str(root / 'Assets.xcassets'))
text = text.replace('- path: Tests/', '- path: ' + str(root / 'Tests') + '/')
text = text.replace('    dependencies:', '      - path: ' + str(root / 'Docs/qa/issue-414/GUIHost.swift') + '\n      - path: ' + str(root / 'Tests/SudrfAppTests/Fixtures/issue414_ezhva_appeals.json') + '\n        buildPhase: resources\n    dependencies:', 1)
text = text.replace('path: Generated/', 'path: ' + str(build / 'Generated') + '/')
text = text.replace('PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.app.debug\n',
                    'PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue414\n')
text = text.replace('PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.app\n',
                    'PRODUCT_BUNDLE_IDENTIFIER: ru.sudrf.qa.issue414\n')
text = text.replace('SUDRF_DISPLAY_NAME: Sudrf Debug\n',
                    'SUDRF_DISPLAY_NAME: Sudrf414QA\n')
text = text.replace('CODE_SIGN_STYLE: Automatic', 'CODE_SIGN_STYLE: Manual')
(build / 'project.yml').write_text(text)
PYCONFIG
(cd "$QA_BUILD" && xcodegen generate)
xcodebuild -project "$QA_BUILD/Sudrf.xcodeproj" -scheme Sudrf -configuration Debug \
  -derivedDataPath "$QA_BUILD/DerivedData" CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES build > /private/tmp/sudrf-414/xcode-qa-build.log 2>&1
printf '%s\n' "$QA_BUILD/DerivedData/Build/Products/Debug/Sudrf-Debug.app"
