# Wacom Native Input Bridge

Cross-platform localhost bridge for receiving native Wacom touch and pen input
from Windows and macOS applications.

The bridge captures native tablet events, normalizes them into a shared JSON
envelope, and exposes them to other applications over HTTP and WebSocket. The
bundled web monitor is an example client for development and device diagnostics;
it is not the core product.

This is an independent project and is not an official Wacom product.

## What it provides

- Native touch capture through WacomMT on Windows and macOS
- Native pen capture through Wintab on Windows and AppKit tablet events on macOS
- Loopback-only HTTP server at `127.0.0.1:8765`
- Real-time WebSocket stream at `ws://127.0.0.1:8765/ws`
- Device capabilities, coordinate bounds, counters, and drop metrics
- Independent bounded queues so a slow client cannot block native callbacks
- Small status window with connection state, browser launch, and clean shutdown
- Headless runtime options for integration into another local application

```text
Wacom driver / OS tablet events
              │
              ▼
      Wacom Native Input Bridge
        ├─ GET /health
        ├─ GET /api/status
        └─ WS  /ws
              │
              ├─ your web application
              ├─ desktop application
              └─ bundled example monitor
```

## Use it from another project

Start the bridge, then connect a WebSocket client. The first message is always
`bridge.hello`; later messages are `touch.frame`, `pen.packet`, or
`pen.proximity` events.

```js
const socket = new WebSocket("ws://127.0.0.1:8765/ws");

socket.addEventListener("message", ({ data }) => {
  const message = JSON.parse(data);

  if (message.type === "bridge.hello") {
    console.log("bridge ready", message.protocolVersion, message.status);
  } else if (message.type === "touch.frame") {
    renderTouches(message.touch.contacts);
  } else if (message.type === "pen.packet") {
    renderPen(message.pen);
  } else if (message.type === "pen.proximity") {
    updatePenProximity(message.proximity);
  }
});
```

Use the capability and coordinate bounds in `bridge.hello.status.native` or
`GET /api/status` instead of assuming a fixed tablet resolution. Windows emits
protocol 1 and macOS emits the additive protocol 2. Clients should ignore fields
they do not recognize. See [the protocol reference](docs/PROTOCOL.md) for the
message contract and platform differences.

## Endpoints

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Touch and pen readiness |
| `GET /api/status` | Capabilities, coordinate bounds, counters, and queue metrics |
| `WS /ws` | Native input event stream |
| `GET /` | Bundled example web monitor |

The server accepts only `http://127.0.0.1` or `http://localhost` URLs and binds
to loopback. It is not intended to expose tablet input to a network.

## Run packaged applications

- Windows: `dist/windows/WacomNativeBridge.exe`
- macOS: `dist/macos/WacomNativeBridge.app`

Launching the packaged bridge opens the example monitor in the system default
browser. For another web client, launch with a custom loopback URL/port or host
your client separately and connect it to `/ws`.

Common runtime options:

- `--web-root PATH`
- `--duration SECONDS`
- `--no-browser`
- `--no-window`

Windows selects the endpoint with `--url http://127.0.0.1:PORT`; macOS selects
the port with `--port PORT`.

## Build and test

Windows requires the .NET 10 SDK and Node.js:

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

macOS requires Xcode command-line tools and the Wacom Multi-Touch SDK framework:

```sh
cd native-bridge/macos/bridge
./build.sh
./smoke-test.sh
```

The Wacom driver supplies the runtime native libraries. Windows builds do not
bundle `WacomMT.dll` or `Wintab32.dll`; macOS builds weak-link the installed
`WacomMultiTouch.framework`.

## Repository layout

```text
docs/PROTOCOL.md                  integration contract
examples/web-monitor/            optional browser-based example client
native-bridge/bridge/             Windows bridge host (.NET/WinForms)
native-bridge/bridge-tests/       Windows contract regression tests
native-bridge/macos/bridge/       macOS bridge host (Objective-C++)
native-bridge/macos/diagnostics/  actual-device diagnostic records and tools
native-bridge/vendor/             Wacom Windows wrapper source and license
```

`MACOS_HANDOFF.md` and `native-bridge/WINDOWS_BASELINE.md` are historical
implementation records. They are not the primary integration documentation.

## Example web monitor

The files in `examples/web-monitor` are embedded into packaged builds and served
at `/`. They demonstrate coordinate mapping, pressure, tilt, proximity,
multi-touch, sequence-gap tracking, and platform fallback handling. Replace them
at runtime with `--web-root PATH`, or ignore them and consume the WebSocket from
your own application.

## License

Original bridge code and documentation are available under the
[MIT License](LICENSE).

Wacom wrapper, SDK-derived, sample, header, and vendor files remain subject to
their applicable Wacom license terms. See
[`native-bridge/vendor/wacom/WACOM-SDK-LICENSE.md`](native-bridge/vendor/wacom/WACOM-SDK-LICENSE.md)
and the source notices under `native-bridge/macos/vendor/wacom` before
redistributing those files.
