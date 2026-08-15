#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
output_dir="$script_dir/build"
app_dir="$output_dir/WacomTouchProbe.app"
executable_dir="$app_dir/Contents/MacOS"
mkdir -p "$executable_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

xcrun clang++ \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -fobjc-arc \
  -I"$script_dir/../vendor/wacom/include" \
  -F/Library/Frameworks \
  -weak_framework WacomMultiTouch \
  -framework AppKit \
  "$script_dir/main.mm" \
  -o "$executable_dir/WacomTouchProbe"

codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$script_dir/WacomTouchProbe.entitlements" \
  "$app_dir"

echo "$app_dir"
