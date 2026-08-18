#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

script_dir=${0:A:h}
executable="$script_dir/../../../dist/macos/WacomNativeBridge.app/Contents/MacOS/WacomNativeBridge"
log="$script_dir/build/server-smoke.log"
health="$script_dir/build/health.json"
status_file="$script_dir/build/status.json"
index="$script_dir/build/index-smoke.html"

"$executable" --no-browser --no-window --duration 10 > "$log" 2>&1 &
bridge_pid=$!
trap 'kill "$bridge_pid" 2>/dev/null || true' INT TERM EXIT

ready=false
for _ in {1..50}; do
  if curl --fail --silent http://127.0.0.1:8765/health > "$health"; then
    ready=true
    break
  fi
  sleep 0.1
done

if [[ "$ready" != true ]]; then
  print -u2 "Bridge did not become ready"
  exit 2
fi

curl --fail --silent --show-error http://127.0.0.1:8765/api/status > "$status_file"
curl --fail --silent --show-error http://127.0.0.1:8765/ > "$index"
node "$script_dir/ws-smoke.mjs" 8765

node -e '
  const fs = require("node:fs");
  const health = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const status = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const index = fs.readFileSync(process.argv[3], "utf8");
  if (!health.ok || !health.touchReady || !health.penReady) throw new Error("health not ready");
  if (status.protocolVersion !== 2 || status.url !== "http://127.0.0.1:8765") throw new Error("bad status envelope");
  if (status.native.platform !== "macos" || !status.native.touchDevices.length) throw new Error("missing macOS capabilities");
  if (!index.includes("Wacom Native Input Bridge")) throw new Error("missing example web UI");
  console.log(`http=ok touchReady=${health.touchReady} penReady=${health.penReady} devices=${status.native.touchDevices.length}`);
' "$health" "$status_file" "$index"

wait "$bridge_pid"
trap - INT TERM EXIT
tail -1 "$log"
