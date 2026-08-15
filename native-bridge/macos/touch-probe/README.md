# macOS Wacom touch probe

Minimal diagnostic program for step 4 of `MACOS_HANDOFF.md`.

- Uses the project-local copies of the Wacom API headers.
- Weak-links the driver-installed `WacomMultiTouch.framework` at runtime.
- Registers a finger callback in Observer mode.
- Copies callback data into a fixed-size bounded queue.
- Prints capabilities and touch frames from a separate consumer thread.
- Reports queue drops and callback frame/contact totals on exit.

Build:

```sh
./native-bridge/macos/touch-probe/build.sh
```

Run for 20 seconds:

```sh
./native-bridge/macos/touch-probe/build/WacomTouchProbe.app/Contents/MacOS/WacomTouchProbe --duration 20
```

Observer mode is the default. For comparison with the official sample, the
probe can temporarily use Consumer mode with `--mode consumer`. Consumer mode
may suppress normal system touch handling while the probe is running.

Touch the Cintiq with one or more fingers during the capture. A successful
test prints `CAPABILITIES`, `REGISTER`, touch frames containing `confidence`,
and a non-zero `SUMMARY frames=...` line.

The build is an ad-hoc-signed local `.app` because the Wacom framework uses
the main bundle identifier for its callback Mach service. Its entitlements
match the service names in Wacom's official sample. The framework remains a
driver-installed runtime dependency and is not embedded in the app.
