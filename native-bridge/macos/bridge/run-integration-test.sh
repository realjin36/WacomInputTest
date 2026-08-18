#!/bin/zsh
set -u
unsetopt BG_NICE

script_dir=${0:A:h}
raw_dir="$script_dir/../diagnostics/raw"
executable="$script_dir/../../../dist/macos/WacomNativeBridge.app/Contents/MacOS/WacomNativeBridge"
bridge_log="$raw_dir/bridge-integration.log"
events_log="$raw_dir/bridge-ws-events.jsonl"
summary_log="$raw_dir/bridge-ws-summary.json"

mkdir -p "$raw_dir"
"$executable" --no-browser --no-window --duration 22 > "$bridge_log" 2>&1 &
bridge_pid=$!
trap 'kill "$bridge_pid" 2>/dev/null || true' INT TERM EXIT

ready=false
for _ in {1..50}; do
  if curl --fail --silent http://127.0.0.1:8765/health >/dev/null; then
    ready=true
    break
  fi
  sleep 0.1
done

if [[ "$ready" != true ]]; then
  print -u2 "Bridge did not become ready"
  exit 2
fi

node "$script_dir/ws-capture.mjs" 8765 18000 > "$events_log" 2> "$summary_log"
capture_status=$?
wait "$bridge_pid"
bridge_status=$?
trap - INT TERM EXIT

echo "captureStatus=$capture_status bridgeStatus=$bridge_status"
cat "$summary_log"
tail -1 "$bridge_log"
exit "$capture_status"
