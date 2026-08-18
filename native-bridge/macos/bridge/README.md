# macOS native bridge host

The macOS host combines WacomMultiTouch callbacks and AppKit tablet events with
the same localhost contract used by the Windows bridge. It does not contain or
serve the example monitor and does not open a browser.

Protocol 2 preserves the protocol 1 event names and compatibility fields while
adding AppKit screen coordinates, normalized pressure, tilt, rotation, device
identity, and richer proximity metadata. See
[`../../../docs/PROTOCOL.md`](../../../docs/PROTOCOL.md) and
[`PROTOCOL.md`](PROTOCOL.md).

## Endpoints

- `GET /` — JSON service descriptor
- `GET /health` — touch and pen readiness
- `GET /api/status` — capabilities, bounds, counters, and queue metrics
- `WS /ws` — protocol 2 native input stream

The server binds only to `127.0.0.1`. Loopback browser origins and Origin-less
native clients are allowed by default; other origins require
`--allowed-origin`.

## Build and run

```sh
./build.sh
```

The product is written to `dist/macos/WacomNativeBridge.app`. Launching it shows
a small native status window with touch/pen readiness, client and event/drop
counters, and a Quit button. The close button and Command-Q use the same clean
shutdown path.

Headless diagnostic run:

```sh
../../../dist/macos/WacomNativeBridge.app/Contents/MacOS/WacomNativeBridge \
  --no-window --duration 30
```

Options:

- `--port PORT`
- `--duration SECONDS`
- `--no-window`
- `--allowed-origin ORIGIN` (repeatable)

## Tests

Automated HTTP, WebSocket, static-path, CORS, and origin-policy smoke test:

```sh
./smoke-test.sh
```

Actual-device WebSocket capture:

```sh
./run-integration-test.sh
```

The native test tools are compiled from Swift with the installed Xcode toolchain
and do not require Node.js.

Native input uses a 16,384-event drop-oldest queue. Each WebSocket client has an
independent 1,024-message drop-oldest queue. JSON serialization and socket writes
run outside native callbacks.
