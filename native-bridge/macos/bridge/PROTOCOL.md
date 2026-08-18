# macOS protocol 2 supplement

The cross-platform integration contract is documented in
[`../../../docs/PROTOCOL.md`](../../../docs/PROTOCOL.md). This file preserves
macOS-specific field details and the original actual-device verification record.

`WacomInputBridge`는 기존 Windows protocol 1의 메시지 종류와 필드를 유지하면서 macOS
AppKit 값을 가산 필드로 추가한 protocol 2를 제공한다. 기존 Windows 브리지는 계속 protocol
1을 보내며, 공용 웹 클라이언트는 두 버전을 모두 받아야 한다.

## Endpoints

- HTTP: `http://127.0.0.1:8765`
- WebSocket: `ws://127.0.0.1:8765/ws`
- service descriptor: `GET /`
- readiness: `GET /health`
- capabilities/counters: `GET /api/status`

서버 socket은 `INADDR_LOOPBACK`에만 bind한다. `GET /`는 HTML이 아니라 protocol 2
서비스 설명 JSON을 반환하며 정적 웹 파일 경로는 `404`를 반환한다.

브라우저 Origin은 `localhost`, `127.0.0.1`, `[::1]`을 기본 허용하고 Origin이 없는
네이티브 클라이언트도 허용한다. 그 밖의 Origin은 `--allowed-origin ORIGIN`으로 정확히
추가해야 하며, 허용되지 않은 HTTP 요청과 WebSocket upgrade는 `403`으로 거부한다.

## Common envelope

```json
{
  "sequence": 1,
  "timestampUs": 1786775569048052,
  "source": "wacommt | appkit",
  "type": "touch.frame | pen.packet | pen.proximity",
  "deviceId": 0
}
```

- `sequence`: 브리지 전체에서 단조 증가하는 64-bit 순번. Wacom `FrameNumber`와 별개다.
- `timestampUs`: Unix epoch 기준 microseconds.
- WebSocket 연결 직후 첫 메시지는 sequence가 없는 `bridge.hello`다.
- `bridge.hello.protocolVersion`과 `/api/status.protocolVersion`은 `2`다.

## `touch.frame`

protocol 1의 `state` 문자열을 유지하고 공통 상태인 `commonState`를 추가한다.

```json
{
  "type": "touch.frame",
  "touch": {
    "frameNumber": 123,
    "contacts": [{
      "id": 0,
      "state": "WMTFingerStateDown",
      "commonState": "down",
      "x": 100.5,
      "y": -200.5,
      "width": 16.613,
      "height": 16.610,
      "sensitivity": 0,
      "orientation": 0,
      "confidence": true
    }]
  }
}
```

`commonState` 값은 `none`, `down`, `hold`, `up` 중 하나다. `x/y/width/height`는
WacomMultiTouch 원시 논리 단위를 보존한다. `Confidence=false`도 제거하지 않는다.

## `pen.packet`

기존 Wintab 호환 필드와 AppKit 공통/원시 필드를 함께 보낸다.

```json
{
  "type": "pen.packet",
  "pen": {
    "serial": 14,
    "cursor": 1,
    "x": 412,
    "y": -350,
    "z": 0,
    "pressure": 24929,
    "tangentialPressure": 0,
    "buttons": 1,
    "azimuth": 0,
    "altitude": 0,
    "twist": 0,
    "status": 0,
    "changed": 0,

    "screenX": 412.1445312,
    "screenY": -350.2617188,
    "hasScreenLocation": true,
    "absoluteX": 16592,
    "absoluteY": 10527,
    "absoluteZ": 0,
    "normalizedPressure": 0.380392164,
    "normalizedTangentialPressure": 0,
    "tiltX": 0.3437299722,
    "tiltY": -0.1250038148,
    "rotation": 0,
    "tipDown": true,
    "pointingDeviceType": "pen",
    "uniqueId": 79448682544951,
    "eventTimestamp": 193558.1361
  }
}
```

macOS compatibility fields:

- `x/y`: `screenX/Y`를 정수로 반올림한 값.
- `z`: `absoluteZ`를 정수로 반올림한 값.
- `pressure`: `normalizedPressure × 65535`를 반올림한 값.
- `cursor`: pen `1`, eraser `2`.
- `status & 0x10`: eraser일 때 설정.
- `twist`: AppKit rotation을 0.1도 단위로 변환.
- AppKit에 직접 대응하지 않는 `azimuth`, `altitude`, `changed`는 `0`.

표시 좌표에는 `screenX/Y`를 우선 사용하고, 장치 원형 확인에는 `absoluteX/Y/Z`를 사용한다.
사이드 버튼은 호버 중 AppKit pressure `1`을 만들 수 있으므로 접촉 여부에는 `tipDown`을 우선한다.

## `pen.proximity`

```json
{
  "type": "pen.proximity",
  "proximity": {
    "hardware": true,
    "context": true,
    "entering": true,
    "pointingDeviceType": "eraser",
    "pointingDeviceId": 0,
    "systemTabletId": 1,
    "tabletId": 849,
    "uniqueId": 220220530638647,
    "vendorId": 1386,
    "vendorPointingDeviceType": 2114,
    "capabilityMask": 6087
  }
}
```

macOS에는 Wintab context proximity와 같은 개념이 없으므로 protocol 1 호환 필드 `context`는
`hardware`와 같은 `enteringProximity` 값이다. `entering`이 실제 AppKit 의미를 명시한다.
native `.tabletProximity`와 mouse subtype으로 함께 들어온 동일 proximity는 서버에서 한 번만
전송한다.

## Status additions

`native` 안에 다음 공통/macOS 필드가 추가된다.

- `platform: "macos"`
- `touchCoordinateSpace: "core-graphics-global-logical"`
- `penX`, `penY`: 현재 Cintiq 전역 논리 bounds
- `penCoordinateSpace: "core-graphics-global-logical"`
- `penMaxPressure: 1`
- `touchContacts`, `truncatedTouchFrames`
- `penLocalEvents`, `penGlobalEvents`, `deduplicatedPenEvents`

기존 UI가 읽는 Wintab 상태 필드는 macOS에서도 남겨 둔다. Wintab overlap/promotion 카운터는
macOS에서 항상 `0`이다.

## Backpressure

- native input queue: 16,384 events, drop-oldest
- WebSocket client queue: client별 1,024 messages, drop-oldest
- `/api/status.native.droppedInputEvents`: native queue drop
- `/api/status.droppedClientMessages`: 모든 client queue drop 합계

callback과 AppKit monitor에서는 fixed-size snapshot 복사와 queue push만 한다. JSON 직렬화와
socket send는 worker thread에서 수행한다.

## 2026-08-15 actual-device verification

18초 WebSocket 캡처 결과:

```text
events=1270
touchFrames=1058
touchContacts=2115
maxTouches=2
penPackets=208
positivePressurePackets=156
proximityMessages=4
sequence=1..1270
sequenceGaps=0
invalidMessages=0
inputDropped=0
clientDropped=0
```

pen 및 eraser의 proximity enter/exit, tip pressure, 고유 ID를 모두 확인했다.
