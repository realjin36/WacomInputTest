# Bridge and example-client separation contract

This document defines the target boundary between the Wacom Native Input Bridge
and the optional example web monitor.

## Product boundary

The bridge is a platform-native localhost service. Its responsibilities are:

- capture Wacom touch and pen input through native APIs;
- normalize platform-specific input into the documented protocol;
- expose health, status, and service metadata over HTTP;
- broadcast real-time input over WebSocket;
- report queue pressure and client counters;
- own native-resource startup and clean shutdown.

The bridge must not:

- embed or copy HTML, CSS, or JavaScript;
- serve the example monitor or arbitrary static files;
- launch a browser;
- know the location or implementation of a web client;
- require Node.js to build or run.

The example web monitor is an independent static web project. Its
responsibilities are:

- demonstrate how a browser client connects to the bridge;
- visualize protocol 1 and protocol 2 input;
- allow the bridge endpoint to be configured;
- run from its own development server and port;
- remain optional for bridge users.

## Runtime topology

```text
Wacom driver / OS tablet APIs
              |
              v
WacomNativeBridge process
  HTTP  http://127.0.0.1:8765
  WS    ws://127.0.0.1:8765/ws
              ^
              |
              +-- another web project
              +-- examples/web-monitor (default http://127.0.0.1:8080)
              +-- any non-browser WebSocket client
```

The bridge and the example monitor have independent processes, ports, build
requirements, tests, and distribution artifacts.

## Bridge HTTP and WebSocket surface

The bridge exposes only:

- `GET /` — JSON service descriptor, never HTML;
- `GET /health` — native input readiness;
- `GET /api/status` — capabilities, counters, and queue metrics;
- `WS /ws` — `bridge.hello` followed by native input events.

The service descriptor is platform-neutral except for the protocol version:

```json
{
  "name": "Wacom Native Input Bridge",
  "protocolVersion": 1,
  "health": "/health",
  "status": "/api/status",
  "webSocket": "/ws"
}
```

Unknown HTTP paths return `404`. The bridge does not expose `/index.html`,
`/app.js`, `/styles.css`, or a generic static-file root.

## Command-line interface

The documented cross-platform options are:

- `--port PORT` — loopback port, default `8765`;
- `--duration SECONDS` — optional diagnostic lifetime;
- `--no-window` — run without the status window;
- `--allowed-origin ORIGIN` — explicitly allow an additional browser origin.

The removed options are:

- `--web-root`;
- `--no-browser`.

Windows may retain `--url http://127.0.0.1:PORT` temporarily as an undocumented
compatibility alias, but new integrations use `--port`.

## Status window

The bridge status window contains only:

- bridge running/stopping/error state;
- touch readiness;
- pen readiness;
- connected WebSocket client count;
- event and drop counters;
- quit button.

It has no browser-launch button. Labels use “client,” not “browser,” where the
value represents all WebSocket consumers.

## Example web monitor

The example lives entirely under `examples/web-monitor` and is served separately:

```text
examples/web-monitor/
  index.html
  app.js
  styles.css
  server.mjs
  test.mjs
  README.md
```

Default development URLs:

- monitor: `http://127.0.0.1:8080`;
- bridge HTTP: `http://127.0.0.1:8765`;
- bridge WebSocket: `ws://127.0.0.1:8765/ws`.

The monitor accepts an override such as:

```text
http://127.0.0.1:8080/?bridge=http://127.0.0.1:9876
```

It never derives the bridge endpoint from its own `location.host`.

## Browser-origin policy

The default browser policy is:

- allow loopback origins using `localhost`, `127.0.0.1`, or `[::1]` on any port;
- allow non-browser clients that send no `Origin` header;
- reject other WebSocket origins unless explicitly listed with
  `--allowed-origin`;
- emit CORS response headers only for an allowed origin;
- never use a wildcard origin for native-input endpoints.

This policy separates the example while preventing arbitrary remote pages from
silently consuming local tablet input by default.

## Build and distribution

Bridge artifacts contain native bridge code only:

```text
dist/windows/WacomNativeBridge.exe
dist/windows/WacomNativeBridge.exe.sha256
dist/macos/WacomNativeBridge.app
```

The macOS app has no `Contents/Resources/Web` directory. The Windows executable
has no `WacomNativeBridge.Web.*` manifest resources.

The bridge build requires only platform-native build tools. Node.js is required
only for the example monitor server and test.

Generated bridge binaries belong in GitHub Releases, not in the source tree.

## Test ownership

Native bridge tests verify:

- option parsing and loopback-only binding;
- service descriptor, health, and status endpoints;
- WebSocket handshake and event contract;
- bounded-queue drop accounting;
- origin allow/reject behavior;
- absence of embedded web-monitor resources;
- clean shutdown.

Example-monitor tests verify:

- protocol 1 Windows fallback;
- protocol 2 macOS fields;
- configurable bridge URL handling;
- touch, pen, proximity, and sequence-gap visualization behavior.

The Windows publish script runs native bridge tests only. Example tests run with
their own command and do not block creation of a bridge binary.

## Completion criteria

Separation is complete only when all of the following are true:

1. Running a packaged bridge opens no browser.
2. `GET /` returns JSON rather than the monitor.
3. Static web paths return `404`.
4. Windows and macOS bridge packages contain no monitor files.
5. The example runs from its own server and connects across origins.
6. The example can target a non-default bridge port.
7. Bridge builds and native tests do not require Node.js.
8. Existing touch, pen, pressure, tilt, proximity, and multi-touch behavior pass
   actual-device regression testing.
