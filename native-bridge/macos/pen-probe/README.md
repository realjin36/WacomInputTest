# macOS AppKit pen probe

Minimal diagnostic program for step 5 of `MACOS_HANDOFF.md`.

- Installs both AppKit global and local event monitors.
- Observes native tablet point/proximity events and tablet subtypes attached to
  mouse events.
- Copies event fields into a fixed-size bounded queue before logging them from
  a consumer thread.
- Prints raw position, pressure, tangential pressure, tilt, rotation, buttons,
  proximity, pointing-device type, identifiers, timestamps and event numbers.

Build:

```sh
./native-bridge/macos/pen-probe/build.sh
```

Run for 30 seconds:

```sh
./native-bridge/macos/pen-probe/build/WacomPenProbe.app/Contents/MacOS/WacomPenProbe --duration 30
```

Use the pen over the probe window first to verify the local monitor. Then bring
Chrome to the foreground and repeat hover, tip, pressure, side-button, tilt and
eraser input to verify the global monitor.
