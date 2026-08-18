#!/bin/zsh
set -u
unsetopt BG_NICE

script_dir=${0:A:h}
raw_dir="$script_dir/../diagnostics/raw"
executable="$script_dir/../../../dist/macos/WacomNativeBridge.app/Contents/MacOS/WacomNativeBridge"
bridge_log="$raw_dir/bridge-integration.log"
events_log="$raw_dir/bridge-ws-events.jsonl"
summary_log="$raw_dir/bridge-ws-summary.json"
capture_tool="$script_dir/build/ws-capture"

mkdir -p "$raw_dir"
mkdir -p "$script_dir/build"
xcrun swiftc -parse-as-library \
  -module-cache-path "$script_dir/build/module-cache" \
  "$script_dir/ws-capture.swift" -o "$capture_tool"
"$executable" --no-window --duration 22 > "$bridge_log" 2>&1 &
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

"$capture_tool" 8765 18000 > "$events_log" 2> "$summary_log"
capture_status=$?
wait "$bridge_pid"
bridge_status=$?
trap - INT TERM EXIT

echo "captureStatus=$capture_status bridgeStatus=$bridge_status"
cat "$summary_log"
tail -1 "$bridge_log"
exit "$capture_status"
