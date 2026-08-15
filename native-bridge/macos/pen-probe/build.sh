#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
output_dir="$script_dir/build"
app_dir="$output_dir/WacomPenProbe.app"
executable_dir="$app_dir/Contents/MacOS"
mkdir -p "$executable_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

xcrun clang++ \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -fobjc-arc \
  -fblocks \
  -framework AppKit \
  "$script_dir/main.mm" \
  -o "$executable_dir/WacomPenProbe"

codesign \
  --force \
  --sign - \
  --options runtime \
  "$app_dir"

echo "$app_dir"
