# Example web monitor

This browser UI is an optional client for the Wacom Native Input Bridge. Packaged
bridge builds embed these files and serve them from `/` for diagnostics.

The example demonstrates:

- protocol 1 and protocol 2 fallback handling
- touch-frame state and contact-ID tracking
- Windows Wintab and macOS AppKit coordinate mapping
- pressure, tilt, rotation, eraser, and proximity visualization
- sequence-gap and queue-counter diagnostics

It does not capture Wacom input through browser Pointer Events. All tablet data
comes from `ws://127.0.0.1:8765/ws`.

To bundle a different client while developing, run the bridge with
`--web-root PATH`. Another application may ignore this UI entirely and consume
the documented WebSocket protocol directly.
