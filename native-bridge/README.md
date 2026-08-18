# Native bridge implementations

This directory contains the platform hosts behind the Wacom Native Input Bridge.
The supported integration boundary is the loopback HTTP/WebSocket protocol, not
an in-process C# or Objective-C++ library API.

## Platform hosts

- `bridge/`: Windows x64 host using WacomMT, Wintab, ASP.NET Core, and WinForms
- `macos/bridge/`: macOS host using WacomMultiTouch, AppKit, and a native socket server
- `bridge-tests/`: Windows contract and queue regression tests
- `vendor/`: Wacom Windows wrapper source and its license
- `macos/vendor/`: Wacom macOS headers, sample references, and source notes

Both hosts expose the same endpoint and event families. macOS protocol 2 adds
fields to the Windows protocol 1 compatibility envelope. See
[`../docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Diagnostic programs

`WacomInputProbe.csproj`, `Program.cs`, `run-probe.cmd`, and the macOS probe
directories are low-level device diagnostics. They are not required by a project
that consumes a packaged bridge over WebSocket.
