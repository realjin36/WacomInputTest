#!/bin/zsh
set -u
unsetopt BG_NICE

script_dir=${0:A:h}
macos_dir=${script_dir:h}
raw_dir="$script_dir/raw"
duration=${1:-45}

touch_executable="$macos_dir/touch-probe/build/WacomTouchProbe.app/Contents/MacOS/WacomTouchProbe"
pen_executable="$macos_dir/pen-probe/build/WacomPenProbe.app/Contents/MacOS/WacomPenProbe"
touch_log="$raw_dir/concurrent-touch.log"
pen_log="$raw_dir/concurrent-pen.log"
performance_log="$raw_dir/concurrent-performance.log"

if [[ ! -x "$touch_executable" || ! -x "$pen_executable" ]]; then
  print -u2 "Both probe apps must be built before running this test."
  exit 2
fi

mkdir -p "$raw_dir"

"$touch_executable" --duration "$duration" > "$touch_log" 2>&1 &
touch_pid=$!
"$pen_executable" --duration "$duration" > "$pen_log" 2>&1 &
pen_pid=$!

cleanup() {
  kill "$touch_pid" "$pen_pid" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

{
  echo "duration=${duration}s"
  echo "touchPID=$touch_pid penPID=$pen_pid"
  while kill -0 "$touch_pid" 2>/dev/null || kill -0 "$pen_pid" 2>/dev/null; do
    date '+sample=%Y-%m-%dT%H:%M:%S%z'
    ps -o pid=,pcpu=,rss=,command= -p "$touch_pid,$pen_pid"
    sleep 1
  done
} > "$performance_log" 2>&1 &
monitor_pid=$!

wait "$touch_pid"
touch_status=$?
wait "$pen_pid"
pen_status=$?
wait "$monitor_pid"

trap - INT TERM EXIT

echo "touchStatus=$touch_status penStatus=$pen_status"
echo "touchLog=$touch_log"
echo "penLog=$pen_log"
echo "performanceLog=$performance_log"
