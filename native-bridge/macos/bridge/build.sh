#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h:h}
output_dir="$project_root/dist/macos"
app_dir="$output_dir/WacomNativeBridge.app"
executable_dir="$app_dir/Contents/MacOS"

rm -rf "$app_dir"
mkdir -p "$executable_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

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
