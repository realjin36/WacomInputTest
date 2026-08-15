# Wacom native input probe

Stage 2 diagnostic program for verifying the two native input paths before the
localhost WebSocket bridge is added.

- Touch: `WacomMT.dll`, API v4, finger callback in Observer mode
- Pen: `Wintab32.dll`, private digitizer context and Win32 message loop
- Runtime: .NET 10, Windows x64

The Wacom wrapper source is copied into `vendor/wacom` from Wacom's official
`wacom-device-kit-windows` repository. The driver-installed native DLLs are not
copied into this project.

## Run

```powershell
dotnet run --project .\native-bridge\WacomInputProbe.csproj -- --duration 20
```

During the capture interval, use multiple fingers and move the pen into and out
of proximity. Raw touch contact fields and Wintab packet fields are printed to
the console, followed by event counts.

`run-probe.cmd` performs the same 20-second capture and keeps the console open.

The process must run on the normal interactive desktop. A sandboxed process can
load both Wacom DLLs and open their contexts successfully while still receiving
zero native callbacks/messages.
