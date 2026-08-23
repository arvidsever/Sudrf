#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${FSSP_VENV_DIR:-${HOME}/Library/Application Support/Sudrf/captcha-training/fssp-trainer-venv}"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python3" -m pip install --upgrade pip
"$VENV_DIR/bin/python3" -m pip install --requirement \
  "$SCRIPT_DIR/requirements-fssp-bootstrap.txt"

echo "FSSP trainer ready: $VENV_DIR/bin/python3"
