#!/bin/bash
# Starts the Earmark service if it isn't already running, then returns.
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${EARMARK_PORT:-8765}"
LOG="$DIR/service.log"
export PYTORCH_ENABLE_MPS_FALLBACK=1

if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/status"; then
  exit 0
fi

mkdir -p "$HOME/Earmark"
cd "$DIR"
echo "=== start $(date) arch=$(arch -arm64 /usr/bin/uname -m 2>&1)" >> "$LOG"
nohup arch -arm64 "$DIR/.venv/bin/python" -m earmark.app >> "$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 120); do
  sleep 0.5
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/status" && exit 0
  kill -0 $PID 2>/dev/null || { echo "service exited early" >> "$LOG"; break; }
done
echo "Earmark did not start; see $LOG" >&2
exit 1
