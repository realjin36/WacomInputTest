# Wacom Native Input Bridge — Windows x64 release

The Windows deliverables are:

- `dist/windows/WacomNativeBridge.exe`
- `dist/windows/WacomNativeBridge.exe.sha256`

The executable is a self-contained, compressed, single-file Windows GUI app. A
separate .NET runtime is not required. The installed Wacom driver supplies
`WacomMT.dll` and `Wintab32.dll` at runtime.

## Build

Requirements:

- Windows x64
- .NET 10 SDK
- Wacom driver for actual-device verification

Node.js is not required for bridge tests or builds.

From the repository root:

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

The build runs native contract tests, publishes one x64 Windows GUI executable,
verifies its PE machine/subsystem fields, and writes a SHA-256 checksum.

## Release verification

Before publishing a separated-bridge release, verify on Windows x64 with a
Wacom Cintiq that:

- touch and pen sources report ready;
- `GET /` returns the JSON service descriptor;
- `/index.html`, `/app.js`, and `/styles.css` return `404`;
- allowed loopback origins receive CORS headers and external origins are denied;
- WebSocket hello, touch frames, pen hover/pressure/tilt/buttons/eraser, and
  proximity are delivered;
- intended simultaneous touch and pen input works without drops;
- no browser opens when the executable starts;
- the status-window Quit and close controls stop callbacks, WebSockets, and the
  localhost server;
- the package contains no example-monitor files or manifest resources.

## Distribution

The build script does not perform Authenticode signing. Sign a public release
with your organization's certificate. Attach generated binaries to a GitHub
Release rather than committing them to the source tree.

## Verified release baseline (2026-08-18)

The separated bridge was verified on Windows x64 with a Wacom Cintiq:

- .NET SDK: `10.0.400`
- native regression tests: `8/8` passed
- packaged executable: `WacomNativeBridge.exe` (`60.73 MiB`)
- SHA-256:
  `42d00feea0329e4ef900f8a4d1d554783beaba86d05ff20b138907fa0fee675c`
- the packaged app opened only its status window, with touch and pen ready;
- touch, multitouch, pen pressure, tilt, simultaneous touch and pen, hover, and
  proximity were displayed correctly in the independent example monitor;
- `GET /` returned the service descriptor, `GET /health` reported both input
  sources ready, and `GET /index.html` returned `404`;
- default loopback CORS, external-origin rejection, and an explicit
  `--allowed-origin` were verified;
- the example monitor connected on both the default bridge port and a custom
  `--port 9876` endpoint;
- stopping the example did not stop the bridge, and quitting the bridge closed
  its localhost listener (`curl` status `000`).
