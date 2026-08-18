# Native bridge implementations

This directory contains the Windows and macOS hosts for the Wacom Native Input
Bridge. Consumers integrate through the loopback HTTP/WebSocket protocol rather
than a stable in-process library API.

## Platform hosts

- `bridge/` — Windows x64 host using WacomMT, Wintab, ASP.NET Core, and WinForms
- `macos/bridge/` — macOS host using WacomMultiTouch, AppKit, and native sockets
- `bridge-tests/` — Windows bridge contract, protocol, origin, and queue tests
- `vendor/` — Wacom Windows wrapper source and license
- `macos/vendor/` — Wacom macOS headers, sample references, and source notices

Both hosts expose `GET /`, `GET /health`, `GET /api/status`, and `WS /ws`.
`GET /` is a JSON service descriptor. Neither host contains or serves the
example web monitor.

Windows uses protocol 1. macOS protocol 2 adds fields while preserving protocol
1 event names and compatibility fields. See
[`../docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Builds and tests

Windows:

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

macOS:

```sh
cd native-bridge/macos/bridge
./build.sh
./smoke-test.sh
```

These bridge workflows do not require Node.js. The independently run example
and its Node.js test are under `examples/web-monitor`.

## Diagnostic programs

`WacomInputProbe.csproj`, `Program.cs`, `run-probe.cmd`, and the macOS probe
directories are low-level development tools. They are not required when using a
packaged bridge over WebSocket.
