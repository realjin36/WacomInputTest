# Wacom Native Input Bridge — Windows x64

The Windows deliverable is generated at:

- `dist/windows/WacomNativeBridge.exe`
- `dist/windows/WacomNativeBridge.exe.sha256`

It is a self-contained, compressed, single-file Windows GUI executable. A
separate .NET runtime is not required. The installed Wacom driver supplies
`WacomMT.dll` and `Wintab32.dll` at runtime.

## Build

Requirements:

- Windows x64
- .NET 10 SDK
- Node.js
- Wacom driver for actual-device verification

From the repository root:

```powershell
.\native-bridge\build-windows.ps1
```

The build script first runs the native contract tests and example-client protocol
test. It then verifies that the output is a single x64 PE using the Windows GUI
subsystem and writes its SHA-256 checksum.

## Runtime verification

The bridge behavior was validated on Windows x64 with a Wacom Cintiq:

- Touch and pen native sources report ready
- Single and multi-touch frames are delivered
- Pen hover, pressure, tilt, buttons, eraser, and proximity are delivered
- Two touches and pen input work concurrently in the intended usage range
- The default browser opens the bundled example monitor
- Closing the status window stops callbacks, WebSockets, and the localhost server
- Native contract tests pass 7/7

The original device-validation record is preserved in `WINDOWS_BASELINE.md`.

## Distribution note

The build script does not perform Authenticode signing. Sign the final executable
with your organization's certificate before public distribution. Generated
binaries should be attached to a GitHub Release rather than committed as source.
