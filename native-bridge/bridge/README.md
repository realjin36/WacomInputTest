# Windows native bridge host

The Windows host captures WacomMT touch and Wintab pen input and exposes it on a
loopback-only ASP.NET Core server. Its native status window reports touch/pen
readiness, connected clients, event/drop counters, and provides clean shutdown.
It does not host a web UI or open a browser.

## Endpoints

- `GET /` — JSON service descriptor
- `GET /health` — native input readiness
- `GET /api/status` — capabilities, bounds, counters, and queue metrics
- `WS /ws` — protocol 1 native input stream

The first WebSocket message is `bridge.hello`. Event messages are
`touch.frame`, `pen.packet`, and `pen.proximity`. Each event has a bridge-wide
monotonic `sequence` and a Unix timestamp in microseconds (`timestampUs`).

Native callbacks publish into a 16,384-event drop-oldest queue. Each WebSocket
client has an independent 1,024-message drop-oldest queue, so a slow client does
not stall native capture.

## Run

From the repository root:

```powershell
.\native-bridge\run-bridge.cmd
```

Runtime options:

- `--port PORT`
- `--duration SECONDS`
- `--no-window`
- `--allowed-origin ORIGIN` (repeatable)
- `--url http://127.0.0.1:PORT` (legacy compatibility alias)

The bind URL must remain on `127.0.0.1` or `localhost`. The origin policy allows
loopback browser origins and Origin-less native clients by default. Other web
origins require `--allowed-origin`.

## Lifecycle

`BridgeRuntime` owns native input, Kestrel, the WebSocket pump, cancellation,
status snapshots, and cleanup. Quit, window close, Ctrl+C in a headless build,
and duration expiry converge on the same cancellation path. Shutdown stops
Kestrel, unregisters Wacom callbacks, closes the Wintab context, completes the
input channel, and waits for the event pump.

## Test and build

Requirements: Windows x64 and .NET 10 SDK. Node.js is not required.

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

The native suite verifies options and origin policy, protocol JSON, absence of
embedded web assets, WebSocket hello/events, and bounded-client-queue drops.
The build publishes a self-contained compressed single-file x64 GUI executable
to `dist\windows\WacomNativeBridge.exe` and writes its SHA-256 checksum.

For a diagnostic console build:

```powershell
dotnet run --project .\native-bridge\bridge\WacomNativeBridge.csproj `
  --configuration Release -p:WacomHeadlessBuild=true -- `
  --no-window --duration 5
```

The Wacom driver supplies `WacomMT.dll` and `Wintab32.dll` at runtime.
