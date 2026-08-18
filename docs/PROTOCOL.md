# Wacom Native Input Bridge protocol

The bridge exposes native Wacom input through loopback HTTP and WebSocket. The
Windows implementation uses protocol 1. The macOS implementation uses additive
protocol 2 while retaining protocol 1 event names and compatibility fields.

Clients must inspect `bridge.hello.protocolVersion`, use capability data from the
status payload, and ignore unknown JSON fields.

## Transport

- HTTP base URL: `http://127.0.0.1:8765`
- WebSocket: `ws://127.0.0.1:8765/ws`
- Readiness: `GET /health`
- Capabilities and counters: `GET /api/status`

The bind address is loopback-only. Windows selects a different endpoint with
`--url http://127.0.0.1:PORT`; macOS selects a different port with `--port PORT`.

## Connection handshake

The first WebSocket message is always:

```json
{
  "type": "bridge.hello",
  "protocolVersion": 1,
  "status": {
    "protocolVersion": 1,
    "url": "http://127.0.0.1:8765",
    "native": {
      "platform": "windows",
      "touchReady": true,
      "penReady": true,
      "touchDevices": []
    },
    "webSocketClients": 1,
    "broadcastEvents": 0,
    "droppedClientMessages": 0
  }
}
```

macOS reports protocol version `2` and `native.platform = "macos"`.

Browser clients may report whether they are actively consuming input:

```json
{ "type": "bridge.activate", "generation": 1 }
```

```json
{ "type": "bridge.deactivate", "generation": 2 }
```

The generation is a client-owned monotonically increasing integer. Activation is
used by the Windows bridge when maintaining Wintab foreground overlap; it does not
change the event schema.

## Common event envelope

```json
{
  "sequence": 1,
  "timestampUs": 1786775569048052,
  "source": "wacommt",
  "type": "touch.frame",
  "deviceId": 0
}
```

- `sequence`: bridge-wide monotonically increasing 64-bit sequence number
- `timestampUs`: Unix epoch timestamp in microseconds
- `source`: native source such as `wacommt`, `wintab`, or `appkit`
- `type`: `touch.frame`, `pen.packet`, or `pen.proximity`
- `deviceId`: source device identifier

A sequence gap means the client did not receive one or more bridge events. Check
the status drop counters to distinguish input-queue and client-queue pressure.

## `touch.frame`

One message contains every contact reported in one WacomMT frame.

```json
{
  "type": "touch.frame",
  "touch": {
    "frameNumber": 123,
    "contacts": [{
      "id": 7,
      "state": "WMTFingerStateDown",
      "commonState": "down",
      "x": 100.5,
      "y": 200.5,
      "width": 16.6,
      "height": 16.6,
      "sensitivity": 12,
      "orientation": 45,
      "confidence": true
    }]
  }
}
```

`commonState` is available on macOS protocol 2 and is one of `none`, `down`,
`hold`, or `up`. Protocol 1 clients should map the equivalent WacomMT `state`
strings. A driver may reuse a contact `id` after an up event, so a logical tap
must be identified by state transitions rather than by ID alone.

Use the matching entry in `status.native.touchDevices` to map `x`, `y`, `width`,
and `height`. Do not assume that these values are CSS pixels.

## `pen.packet`

The protocol 1 compatibility fields are:

```json
{
  "type": "pen.packet",
  "pen": {
    "serial": 20,
    "cursor": 1,
    "x": 5000,
    "y": 5000,
    "z": 18,
    "pressure": 1024,
    "tangentialPressure": 0,
    "buttons": 1,
    "azimuth": 900,
    "altitude": 600,
    "twist": 120,
    "status": 0,
    "changed": 1
  }
}
```

Windows values use Wintab axis and orientation units. Normalize pressure with
`status.native.wintabMaxPressure` and coordinates with `wintabX`/`wintabY`.
Azimuth, altitude, and twist are reported in tenths of a degree by the current
Wintab source.

macOS protocol 2 adds AppKit-native fields including:

- `screenX`, `screenY`, `hasScreenLocation`
- `absoluteX`, `absoluteY`, `absoluteZ`
- `normalizedPressure`, `normalizedTangentialPressure`
- `tiltX`, `tiltY`, `rotation`
- `tipDown`, `pointingDeviceType`, `uniqueId`, `eventTimestamp`

Prefer these additive fields when present. `tiltY` follows the native AppKit axis;
a canvas client normally inverts it because Canvas Y increases downward.

## `pen.proximity`

```json
{
  "type": "pen.proximity",
  "proximity": {
    "hardware": true,
    "context": true,
    "entering": true,
    "pointingDeviceType": "pen",
    "uniqueId": 79448682544951
  }
}
```

Protocol 1 guarantees `hardware` and `context`. Protocol 2 adds AppKit proximity
metadata such as `entering`, `pointingDeviceType`, tablet IDs, vendor IDs, and
capability mask. Treat a false/exit proximity event as removal of the active pen
or eraser visualization.

## Status and coordinate capabilities

Common fields under `status.native` include:

- `platform`, `touchReady`, `penReady`
- `touchDevices`
- `producedEvents`, `droppedInputEvents`
- `touchFrames`, `penPackets`, `proximityMessages`
- `activeBrowserClients`

Windows additionally reports Wintab axis, pressure, proximity, overlap, and
promotion fields. macOS additionally reports common screen coordinate spaces,
pen bounds, contact totals, truncation, local/global event totals, and dedupe
counters. The status response is intentionally extensible.

## Backpressure

- Native input queue: 16,384 events, drop-oldest
- Per-WebSocket-client queue: 1,024 messages, drop-oldest
- Native drops: `status.native.droppedInputEvents`
- Client drops: `status.droppedClientMessages`

Native callbacks only copy fixed-size snapshots and enqueue them. JSON
serialization and socket writes run outside the callback path.

## Compatibility rules

1. Branch on message `type`, not on object shape alone.
2. Use `protocolVersion` and `native.platform` for platform-specific behavior.
3. Ignore unknown fields so additive protocol versions remain compatible.
4. Use capability bounds for coordinates and pressure.
5. Use `sequence` to detect gaps.
6. Use touch state transitions to distinguish taps when contact IDs are reused.
