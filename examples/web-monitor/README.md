# Example web monitor

This directory contains an optional browser client for the Wacom Native Input
Bridge. It is an independent static web project: bridge packages do not embed,
copy, serve, or launch it.

The monitor demonstrates:

- protocol 1 Windows and protocol 2 macOS handling
- touch-frame state and contact-ID tracking
- Wintab and AppKit coordinate mapping
- pressure, tilt, rotation, buttons, eraser, and proximity visualization
- sequence-gap and queue-counter diagnostics

It does not capture Wacom touch or pen through browser Pointer Events. All
tablet data comes from the separately running native bridge.

## Run

1. Start `WacomNativeBridge`.
2. Start the example server from the repository root:

   ```sh
   node examples/web-monitor/server.mjs
   ```

3. Open `http://127.0.0.1:8080`.

The example server binds to `127.0.0.1` and serves only this directory's known
HTML, JavaScript, and CSS files. To select another monitor port:

```sh
node examples/web-monitor/server.mjs --port 8081
```

The monitor connects to `http://127.0.0.1:8765` by default. Override the bridge
base URL with the `bridge` query parameter:

```text
http://127.0.0.1:8080/?bridge=http://127.0.0.1:9876
```

For a non-loopback monitor origin, start the bridge with an exact explicit
allowlist entry, for example:

```text
--allowed-origin https://monitor.example.test
```

## Test

```sh
node examples/web-monitor/test.mjs
```

The test covers configurable bridge endpoints, protocol 1 Windows fallbacks,
protocol 2 macOS fields, touch and pen visualization, proximity cleanup, and
sequence-gap accounting.
