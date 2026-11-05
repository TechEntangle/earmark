#!/bin/bash
# Runs Earmark in the foreground so you can see errors. Ctrl-C to stop.
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" && arch -arm64 "$DIR/.venv/bin/python" -m earmark.app
