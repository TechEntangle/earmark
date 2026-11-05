#!/bin/bash
# End-to-end browser tests against a simulated pendant. Safe to run while Earmark is running.
DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/.venv/bin/python"
arch -arm64 "$PY" -m pip install -q pytest playwright && arch -arm64 "$PY" -m playwright install chromium >/dev/null
cd "$DIR" && arch -arm64 "$PY" -m pytest tests -q "$@"
