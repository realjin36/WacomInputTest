#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h:h}
output_dir="$project_root/dist/macos"
app_dir="$output_dir/WacomNativeBridge.app"
executable_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources/Web"

rm -rf "$app_dir"
mkdir -p "$executable_dir" "$resources_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_root/examples/web-monitor/index.html" "$resources_dir/index.html"
cp "$project_root/examples/web-monitor/app.js" "$resources_dir/app.js"
cp "$project_root/examples/web-monitor/styles.css" "$resources_dir/styles.css"

xcrun clang++ \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -fobjc-arc \
  -fblocks \
  -pthread \
  -I"$script_dir/../vendor/wacom/include" \
  -F/Library/Frameworks \
  -weak_framework WacomMultiTouch \
  -framework AppKit \
  -framework Foundation \
  "$script_dir/main.mm" \
  "$script_dir/NativeInputSource.mm" \
  "$script_dir/LocalServer.mm" \
  -o "$executable_dir/WacomNativeBridge"

codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$script_dir/WacomInputBridge.entitlements" \
  "$app_dir"

echo "$app_dir"
