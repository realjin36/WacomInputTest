# macOS native input bridge

This target combines the validated WacomMultiTouch callback and AppKit tablet
event monitors with the localhost HTTP/WebSocket contract used by the Windows
bridge.

Protocol version 2 is additive: the existing `touch.frame`, `pen.packet`, and
`pen.proximity` event names and compatibility fields remain. AppKit pen packets
also include `screenX`, `screenY`, `absoluteX/Y/Z`, `normalizedPressure`,
`normalizedTangentialPressure`, `tiltX`, `tiltY`, `rotation`,
`pointingDeviceType`, and `uniqueId`.

See `PROTOCOL.md` for the full compatibility contract and actual-device result.

The server binds only to `127.0.0.1` and provides:

- `GET /health`
- `GET /api/status`
- `WS /ws`
- `/`, `/index.html`, `/app.js`, `/styles.css`

Build:

```sh
./build.sh
```

The packaged product is written to `dist/macos/WacomInputTest.app`. Launching
the app starts the loopback server and opens `http://127.0.0.1:8765` in the
user's macOS default browser. If that fails, it prints the URL for manual access.
While the bridge is running, a small status window shows Touch/Pen readiness,
event and browser-client counts, and drop counters. Its Open Browser button
opens the localhost page again in the macOS default browser. Use the Quit
button, close button, or Command-Q to stop input callbacks and the localhost
server cleanly.

Diagnostic run without browser launch:

```sh
../../../dist/macos/WacomInputTest.app/Contents/MacOS/WacomInputTest --no-browser --no-window --duration 30
```

Input callbacks publish fixed-size snapshots to a 16,384-event bounded queue.
JSON serialization and socket writes happen on worker threads. Each WebSocket
client has an independent 1,024-message drop-oldest queue.

Automated endpoint/handshake smoke test:

```sh
./smoke-test.sh
```

Actual-device WebSocket capture:

```sh
./run-integration-test.sh
```
