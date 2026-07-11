#!/bin/bash
# fetch-model.sh — скачивает immutable CoreML asset из GitHub Release,
# verify'ит manifest уже существующим Scripts/verify-model.sh, и затем
# verify-before-replace в $FIXTURES_DIR.
#
# Это **verify-before-replace**, не атомарная операция: короткий gap между
# `rm` и `mv` допустим для single-job CI (нет параллельных fetchers).
#
# Bash 3.2 compatible (system macOS Bash). Использует `gh release download`
# с `contents: read` permission; не требует `contents: write`.
#
# Параметры:
#   --asset-tag TAG    GitHub release tag (например, model-v1)
#   --fixtures-dir DIR Корень Fixtures/ (manifest + .mlmodelc/)
#
# Используется в CI (.github/workflows/swift.yml):
#   - build-test: перед swift test
#   - package-app: перед make-app.sh --ci

set -euo pipefail

ASSET_TAG=""
FIXTURES_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --asset-tag)
            [[ $# -ge 2 ]] || { echo "--asset-tag requires a value" >&2; exit 2; }
            ASSET_TAG="$2"
            shift 2
            ;;
        --fixtures-dir)
            [[ $# -ge 2 ]] || { echo "--fixtures-dir requires a value" >&2; exit 2; }
            FIXTURES_DIR="$2"
            shift 2
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

[[ -n "$ASSET_TAG" ]] || { echo "--asset-tag required" >&2; exit 2; }
[[ -n "$FIXTURES_DIR" ]] || { echo "--fixtures-dir required" >&2; exit 2; }
[[ -d "$FIXTURES_DIR" && ! -L "$FIXTURES_DIR" ]] || { echo "--fixtures-dir not a directory: $FIXTURES_DIR" >&2; exit 2; }

MANIFEST="$FIXTURES_DIR/MODEL_MANIFEST.sha256"
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST (pre-A5 commit required)" >&2; exit 1; }

# Staging в ТОЙ ЖЕ файловой системе, что и workspace, чтобы `mv` был
# атомарным rename в пределах одной FS.
STAGING="$FIXTURES_DIR/.staging-fetch-$$"
mkdir "$STAGING" || { echo "cannot create staging dir: $STAGING" >&2; exit 1; }
trap 'rm -rf "$STAGING"' EXIT

# 1. Download с GitHub Release
gh release download "$ASSET_TAG" \
    --pattern "model-captcha-numeric-v*.zip" \
    --dir "$STAGING" \
    --clobber || { echo "gh release download failed (tag=$ASSET_TAG)" >&2; exit 1; }

# 2. Ровно один ZIP. Используем find + read-loop, а не `ls | wc -l`,
#    чтобы `set -euo pipefail` не ловила пустой glob.
mapfile_compat=()
while IFS= read -r path; do
    mapfile_compat+=("$path")
done < <(find "$STAGING" -maxdepth 1 -type f -name 'model-captcha-numeric-v*.zip' -print)
if [[ ${#mapfile_compat[@]} -ne 1 ]]; then
    echo "expected exactly 1 model ZIP in $STAGING, got ${#mapfile_compat[@]}" >&2
    exit 1
fi
ZIP="${mapfile_compat[0]}"

# 3. Распаковка
unzip -o "$ZIP" -d "$STAGING" || { echo "unzip failed: $ZIP" >&2; exit 1; }

# 4. Verify ДО mv (verify-before-replace).
bash "$(dirname "$0")/verify-model.sh" \
    --model-dir "$STAGING/model-captcha-numeric.mlmodelc" \
    --manifest "$MANIFEST" || { echo "verify failed" >&2; exit 1; }

# 5. Replace: best-effort atomic rename в одной FS.
#    Между `rm` и `mv` короткий gap; single-job CI не запускает fetch
#    параллельно, поэтому никто не увидит пустой target.
TARGET="$FIXTURES_DIR/model-captcha-numeric.mlmodelc"
[[ -d "$TARGET" ]] && rm -rf "$TARGET"
mv "$STAGING/model-captcha-numeric.mlmodelc" "$TARGET" || { echo "mv failed: $STAGING → $TARGET" >&2; exit 1; }

# 6. Cleanup (unzip + оставшийся ZIP).
rm -rf "$STAGING"
trap - EXIT

echo "fetched and verified: $TARGET (tag=$ASSET_TAG)"
