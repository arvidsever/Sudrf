#!/bin/bash
# Проверяет полный состав скомпилированной CoreML-модели по tracked manifest.
# Совместим с системным Bash 3.2 в macOS.

set -euo pipefail

MODEL_DIR=""
MANIFEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model-dir)
            [[ $# -ge 2 ]] || { echo "--model-dir requires a value" >&2; exit 2; }
            MODEL_DIR="$2"
            shift 2
            ;;
        --manifest)
            [[ $# -ge 2 ]] || { echo "--manifest requires a value" >&2; exit 2; }
            MANIFEST="$2"
            shift 2
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

[[ -d "$MODEL_DIR" && ! -L "$MODEL_DIR" ]] || { echo "invalid --model-dir: $MODEL_DIR" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "invalid --manifest: $MANIFEST" >&2; exit 1; }

MANIFEST_RAW=$(mktemp)
MANIFEST_PATHS=$(mktemp)
ACTUAL_PATHS=""

cleanup() {
    rm -f "$MANIFEST_RAW" "$MANIFEST_PATHS" "${ACTUAL_PATHS:-}"
}
trap cleanup EXIT

# Every line has exactly two whitespace-separated fields; empty lines are invalid.
awk -v file="$MANIFEST" '
    NF != 2 {
        printf("FAIL %s: line %d: expected 2 fields, got %d: %s\\n", file, NR, NF, $0) > "/dev/stderr"
        bad = 1
    }
    NF == 2 { print $1 "\t" $2 }
    END { exit bad }
' "$MANIFEST" > "$MANIFEST_RAW" || { echo "manifest parse failed" >&2; exit 1; }

[[ -s "$MANIFEST_RAW" ]] || { echo "manifest is empty" >&2; exit 1; }
awk -F'\t' '{ print $2 }' "$MANIFEST_RAW" | sort > "$MANIFEST_PATHS"

while IFS=$'\t' read -r hash rel; do
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "bad hash: $hash" >&2; exit 1; }
    case "$rel" in
        model-captcha-numeric.mlmodelc/*) ;;
        *) echo "bad manifest path: $rel" >&2; exit 1 ;;
    esac
    [[ "$rel" != *..* && "$rel" != /* ]] || { echo "unsafe manifest path: $rel" >&2; exit 1; }
done < "$MANIFEST_RAW"

if duplicates=$(uniq -d "$MANIFEST_PATHS") && [[ -n "$duplicates" ]]; then
    echo "duplicate manifest paths: $duplicates" >&2
    exit 1
fi

# Directories and regular files are the only permitted nodes in the model tree.
if bad_nodes=$(find "$MODEL_DIR" -mindepth 1 ! -type d ! -type f -print) && [[ -n "$bad_nodes" ]]; then
    echo "non-regular nodes in model: $bad_nodes" >&2
    exit 1
fi

ACTUAL_PATHS=$(mktemp)
(cd "$MODEL_DIR" && find . -type f | sed 's|^\./|model-captcha-numeric.mlmodelc/|' | sort) > "$ACTUAL_PATHS"

if unlisted=$(comm -23 "$ACTUAL_PATHS" "$MANIFEST_PATHS") && [[ -n "$unlisted" ]]; then
    echo "unlisted model files: $unlisted" >&2
    exit 1
fi

if missing=$(comm -13 "$ACTUAL_PATHS" "$MANIFEST_PATHS") && [[ -n "$missing" ]]; then
    echo "manifest files missing from model: $missing" >&2
    exit 1
fi

while IFS= read -r rel; do
    suffix=${rel#model-captcha-numeric.mlmodelc/}
    actual=$(shasum -a 256 "$MODEL_DIR/$suffix" | awk '{print $1}')
    expected=$(awk -F'\t' -v rel="$rel" '$2 == rel { print $1; exit }' "$MANIFEST_RAW")
    [[ "$actual" == "$expected" ]] || { echo "hash mismatch: $rel" >&2; exit 1; }
done < "$ACTUAL_PATHS"

echo "OK: $MODEL_DIR matches manifest"
