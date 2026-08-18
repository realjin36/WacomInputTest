# Wacom Native Input Bridge

Cross-platform localhost service for receiving native Wacom touch and pen input
on Windows and macOS.

The bridge captures tablet events through platform-native APIs, normalizes them
into a shared JSON protocol, and makes them available to other applications over
HTTP and WebSocket. The web monitor under `examples/` is an optional, separately
run client for development and device diagnostics.

This is an independent project and is not an official Wacom product.

## Features

- WacomMT touch capture on Windows and macOS
- Wintab pen capture on Windows
- AppKit tablet-event capture on macOS
- Loopback-only HTTP and WebSocket service
- Touch frames, pen pressure, tilt, buttons, eraser, and proximity events
- Device bounds, capabilities, event counters, and queue-drop metrics
- Bounded queues so a slow client cannot block native input callbacks
- Small native status window with touch/pen readiness and clean shutdown
- Headless and configurable-port operation for local integrations

```text
Wacom driver / native OS APIs
              |
              v
   Wacom Native Input Bridge
     HTTP 127.0.0.1:8765
     WS   127.0.0.1:8765/ws
              ^
              |
              +-- your web application
              +-- your desktop application
              +-- examples/web-monitor (optional, port 8080)
```

The supported integration boundary is the localhost protocol. The repository
does not currently provide a stable in-process C# or Objective-C++ library API.

## Use it from another project

Start the packaged bridge and connect to its WebSocket endpoint. The first
message is `bridge.hello`; subsequent messages are `touch.frame`, `pen.packet`,
or `pen.proximity`.

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

Use `bridge.hello.status.native` or `GET /api/status` for coordinate bounds and
capabilities instead of assuming a fixed tablet resolution. Windows emits
protocol 1; macOS emits additive protocol 2. Clients should ignore unknown
fields. See [the protocol reference](docs/PROTOCOL.md).

## HTTP and WebSocket endpoints

| Endpoint | Purpose |
| --- | --- |
| `GET /` | JSON service descriptor |
| `GET /health` | Touch and pen readiness |
| `GET /api/status` | Capabilities, bounds, counters, and queue metrics |
| `WS /ws` | Native input event stream |

The bridge does not serve HTML, JavaScript, CSS, or arbitrary files. Unknown
paths, including `/index.html`, return `404`.

## Run packaged applications

- Windows: `dist/windows/WacomNativeBridge.exe`
- macOS: `dist/macos/WacomNativeBridge.app`

Starting the bridge opens only its native status window. It does not open a
browser. Use the Quit button, the window close control, or the normal platform
quit shortcut to stop the native callbacks and local server cleanly.

Common options:

- `--port PORT` — loopback port; default `8765`
- `--duration SECONDS` — optional diagnostic lifetime
- `--no-window` — run headlessly
- `--allowed-origin ORIGIN` — allow an additional HTTP/HTTPS browser origin

Windows temporarily retains `--url http://127.0.0.1:PORT` as a compatibility
alias. New integrations should use `--port`.

## Browser-origin security

Tablet data is local but sensitive. The bridge therefore:

- allows browser origins on `localhost`, `127.0.0.1`, and `[::1]` on any port;
- allows non-browser clients that omit the `Origin` header;
- rejects other origins unless explicitly listed with `--allowed-origin`;
- returns an exact `Access-Control-Allow-Origin` value only to allowed origins;
- never uses a wildcard CORS origin.

Do not expose the bridge through a public network proxy without adding an
appropriate authentication and authorization layer.

## Build and test

### Windows

Requirements: Windows x64 and the .NET 10 SDK. Node.js is not required to build
or test the bridge.

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

The build creates a self-contained x64 executable and checksum under
`dist\windows`.

### macOS

Requirements: Xcode command-line tools and the Wacom Multi-Touch SDK framework.

```sh
cd native-bridge/macos/bridge
./build.sh
./smoke-test.sh
```

The build creates `dist/macos/WacomNativeBridge.app`. The bridge weak-links the
installed Wacom framework and does not bundle the SDK framework.

### Optional example monitor

The monitor has its own Node.js server and tests; neither is part of a bridge
build.

```sh
node examples/web-monitor/server.mjs
node examples/web-monitor/test.mjs
```

Open `http://127.0.0.1:8080`. To target a different bridge port:

```text
http://127.0.0.1:8080/?bridge=http://127.0.0.1:9876
```

## Repository layout

```text
docs/PROTOCOL.md                  public integration protocol
docs/SEPARATION_CONTRACT.md       bridge/example product boundary
examples/web-monitor/            independently run example client
native-bridge/bridge/             Windows bridge host (.NET/WinForms)
native-bridge/bridge-tests/       Windows native contract tests
native-bridge/macos/bridge/       macOS bridge host (Objective-C++)
native-bridge/macos/diagnostics/  actual-device diagnostic records and tools
native-bridge/vendor/             Wacom Windows wrapper source and license
```

`MACOS_HANDOFF.md` and `native-bridge/WINDOWS_BASELINE.md` are historical
implementation records and may describe earlier bundled-monitor builds.

## Runtime dependencies and licensing

The installed Wacom driver supplies the runtime native components. Windows
packages do not bundle `WacomMT.dll` or `Wintab32.dll`; macOS packages do not
bundle `WacomMultiTouch.framework`.

Original bridge code and documentation are available under the
[MIT License](LICENSE). Wacom wrapper, SDK-derived, sample, header, and vendor
files remain subject to their applicable Wacom terms. See
[`native-bridge/vendor/wacom/WACOM-SDK-LICENSE.md`](native-bridge/vendor/wacom/WACOM-SDK-LICENSE.md)
and the notices under `native-bridge/macos/vendor/wacom` before redistribution.
