#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

script_dir=${0:A:h}
executable="$script_dir/../../../dist/macos/WacomNativeBridge.app/Contents/MacOS/WacomNativeBridge"
log="$script_dir/build/server-smoke.log"
health="$script_dir/build/health.json"
status_file="$script_dir/build/status.json"
service="$script_dir/build/service.json"
headers="$script_dir/build/cors-headers.txt"
ws_smoke="$script_dir/build/ws-smoke"

mkdir -p "$script_dir/build"
xcrun swiftc -parse-as-library \
  -module-cache-path "$script_dir/build/module-cache" \
  "$script_dir/ws-smoke.swift" -o "$ws_smoke"

"$executable" --no-window --duration 10 \
  --allowed-origin https://allowed.example > "$log" 2>&1 &
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
curl --fail --silent --show-error http://127.0.0.1:8765/ > "$service"
"$ws_smoke" 8765

[[ "$(plutil -extract ok raw -o - "$health")" == "true" ]]
[[ "$(plutil -extract touchReady raw -o - "$health")" == "true" ]]
[[ "$(plutil -extract penReady raw -o - "$health")" == "true" ]]
[[ "$(plutil -extract protocolVersion raw -o - "$status_file")" == "2" ]]
[[ "$(plutil -extract url raw -o - "$status_file")" == "http://127.0.0.1:8765" ]]
[[ "$(plutil -extract native.platform raw -o - "$status_file")" == "macos" ]]
[[ "$(plutil -extract name raw -o - "$service")" == "Wacom Native Input Bridge" ]]
[[ "$(plutil -extract protocolVersion raw -o - "$service")" == "2" ]]

static_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  http://127.0.0.1:8765/index.html)
[[ "$static_status" == "404" ]]

curl --fail --silent --show-error --dump-header "$headers" --output /dev/null \
  --header 'Origin: http://127.0.0.1:8080' http://127.0.0.1:8765/api/status
/usr/bin/grep -Eiq '^Access-Control-Allow-Origin: http://127\.0\.0\.1:8080' "$headers"

curl --fail --silent --show-error --dump-header "$headers" --output /dev/null \
  --header 'Origin: https://allowed.example' http://127.0.0.1:8765/api/status
/usr/bin/grep -Eiq '^Access-Control-Allow-Origin: https://allowed\.example' "$headers"

blocked_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header 'Origin: https://blocked.example' http://127.0.0.1:8765/api/status)
[[ "$blocked_status" == "403" ]]

print "http=ok service=json static=404 cors=ok origin-rejection=ok"

wait "$bridge_pid"
trap - INT TERM EXIT
tail -1 "$log"
