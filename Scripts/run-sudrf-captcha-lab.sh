#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
training_root="${HOME}/Library/Application Support/Sudrf/captcha-training"
python="${training_root}/fssp-trainer-venv/bin/python3"

if [[ ! -x "$python" ]]; then
  echo "Сначала запустите: bash Scripts/setup-fssp-bootstrap.sh" >&2
  exit 1
fi

cd "$repo_root"
exec "$python" Scripts/sudrf-captcha-curator.py "$@"
