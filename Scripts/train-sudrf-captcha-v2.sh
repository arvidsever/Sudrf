#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
training_root="${HOME}/Library/Application Support/Sudrf/captcha-training"
python="${training_root}/fssp-trainer-venv/bin/python3"
corpus="${1:-${training_root}/solved-numeric-curated}"

if [[ ! -x "$python" ]]; then
  echo "Сначала запустите: bash Scripts/setup-fssp-bootstrap.sh" >&2
  exit 1
fi
if [[ $# -gt 0 ]]; then shift; fi

cd "$repo_root"
exec "$python" -u Scripts/train-sudrf-numeric-v2.py \
  --corpus "$corpus" \
  --output-dir "$training_root" \
  --device mps \
  "$@"
