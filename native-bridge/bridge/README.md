# Local HTTP and WebSocket bridge

The bridge listens only on `127.0.0.1:8765` and serves the existing test page.
The page consumes only this native stream; browser Pointer Events are not used
for the visualization.

## Endpoints

- `GET /` - existing `index.html`
- `GET /app.js`
- `GET /styles.css`
- `GET /health` - native input readiness
- `GET /api/status` - capabilities, counters and queue-drop metrics
- `WS /ws` - normalized native input stream

The first WebSocket message is always `bridge.hello`. Subsequent messages use
protocol version 1 and one of these event types:

- `touch.frame` - one WacomMT frame with every contact in that frame
- `pen.packet` - one Wintab packet, including raw orientation values
- `pen.proximity` - Wintab hardware/context proximity state

Each event contains a bridge-wide monotonic `sequence` and a Unix timestamp in
microseconds (`timestampUs`). Touch callbacks and Wintab messages publish into a
16,384-event bounded queue. Each WebSocket client has an independent 1,024-message
bounded queue so that one slow browser cannot stall native input capture.

`/api/status` and `bridge.hello` also include WacomMT logical bounds and Wintab
X/Y native axis bounds. The web UI uses those values to map both devices into
the same canvas.

Run `..\run-bridge.cmd`. The bridge opens <http://127.0.0.1:8765> in the
Windows default browser.

## Runtime lifecycle

`BridgeRuntime` owns native input, Kestrel, the WebSocket pump, cancellation,
status snapshots, and cleanup. Normal execution runs a fixed-size WinForms
status window while the bridge stays on background threads. The window reports
Touch/Pen readiness, event/client counters and drop counters, and exposes browser
and clean-shutdown buttons.

Runtime options:

- `--url http://127.0.0.1:PORT`
- `--web-root PATH`
- `--duration SECONDS`
- `--no-browser`
- `--no-window` (run the bridge headlessly for diagnostics and automation)

`RequestStop`, Ctrl+C, duration expiry, and the future GUI close action converge
on the same cancellation path. Shutdown stops and disposes Kestrel, unregisters
Wacom callbacks, closes the Wintab context, completes the input channel, and
waits for the WebSocket event pump. A localhost bind/startup failure returns exit
code 3 instead of leaving partially initialized native resources alive.

The Windows status payload explicitly reports `native.platform = "windows"`.
Protocol 1 remains unchanged; the shared web UI prefers common macOS fields when
present and otherwise uses the existing WacomMT state and Wintab axis, pressure,
orientation, status, and button fields.

Run the shared-UI protocol regression test from the repository root:

```sh
node native-bridge/bridge/web-compat-test.mjs
```
