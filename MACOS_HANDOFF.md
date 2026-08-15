# Wacom Native Input Monitor — macOS 구현 인수인계

이 문서는 Windows에서 완성된 현재 프로젝트를 macOS 환경의 새 Codex 작업으로 옮겨, macOS 버전을 구현하기 위한 전체 맥락을 제공한다. 새 작업은 과거 대화가 없다고 가정하고 이 문서와 실제 소스 코드를 함께 읽어야 한다.

## 새 Codex에게 먼저 전달할 요청

> `MACOS_HANDOFF.md`를 처음부터 끝까지 읽고 현재 소스와 대조해라. 기존 Windows 버전은 보존하고, 웹 UI와 WebSocket 프로토콜을 최대한 공유하는 macOS 버전을 구현해라. macOS Wacom SDK나 샘플에서 필요한 파일은 프로젝트 밖의 경로를 직접 참조하지 말고 반드시 이 프로젝트 안의 macOS 전용 vendor 폴더로 복사한 뒤 그 경로를 사용해라. 먼저 장치·SDK·Xcode·드라이버 환경을 조사하고, 실제 Cintiq에서 터치와 펜을 각각 검증한 다음 통합해라.

## 1. 프로젝트 목적과 제약

목적은 Wacom Cintiq Pro에서 발생하는 다음 입력을 로컬 웹 화면에 실시간으로 시각화하는 것이다.

- 마우스
- 최대 동시 멀티터치
- 펜 접촉과 hover/proximity
- 펜 압력, 버튼, 기울기, 회전/twist, 지우개
- 터치와 펜의 동시 입력
- 터치 접점의 `Confidence`
- 네이티브 입력 상태와 누락·큐 드롭 진단 정보

이 앱은 일회성 장치 테스트 도구다.

- 외부 배포나 웹 호스팅은 하지 않는다.
- 서버는 반드시 localhost에만 바인딩한다.
- UI는 미니멀하게 유지한다.
- Windows에서는 Windows + Chrome + Cintiq Pro만 대상으로 했다.
- macOS에서도 macOS + Chrome + Cintiq Pro만 대상으로 해도 된다.
- 현재 프로젝트에는 Git 저장소가 없다. 사용자가 별도로 요청하기 전에는 버전 관리 도입을 전제로 삼지 않는다.
- 공식 SDK 또는 샘플에서 필요한 파일이 있으면 외부 다운로드 폴더를 직접 참조하지 말고 이 프로젝트 아래에 복사하여 사용한다.
- Windows용 Wacom SDK 파일은 이미 `native-bridge/vendor/wacom` 아래에 복사되어 있다. 이를 macOS SDK로 덮어쓰지 않는다.

## 2. 현재 Windows 버전 상태

Windows 버전은 현재 필요한 기능이 정상 동작하는 것으로 사용자 확인이 끝났다.

실행 방법:

1. 프로젝트 루트의 `WacomInputTest.exe` 실행
2. 브리지가 `http://127.0.0.1:8765`에서 시작
3. Chrome이 해당 주소로 자동 실행
4. 실행 파일 안에 `index.html`, `app.js`, `styles.css`가 embedded resource로 포함됨
5. 브리지 프로세스를 닫으면 네이티브 입력 수집과 로컬 서버가 함께 종료됨

현재 실행 파일은 `win-x64`, framework-dependent single-file이다. 소스 빌드는 .NET 10을 사용한다.

```powershell
dotnet publish native-bridge\bridge\WacomLocalBridge.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained false `
  --output native-bridge\single-file `
  --no-restore `
  -p:PublishSingleFile=true `
  -p:DebugType=None `
  -p:DebugSymbols=false
```

## 3. 현재 파일 역할

### 실제 제품 코드

- `index.html`: 단일 테스트 화면 구조
- `styles.css`: 미니멀한 레이아웃과 입력별 색상
- `app.js`: WebSocket 수신, 좌표 변환, 입력 상태, Canvas 렌더링, 상태 패널
- `native-bridge/bridge/Program.cs`: Kestrel HTTP/WebSocket 서버, embedded web asset 제공, Chrome 실행
- `native-bridge/bridge/InputModels.cs`: WebSocket으로 전송하는 정규화된 데이터 모델
- `native-bridge/bridge/WacomNativeInputSource.cs`: Windows WacomMT + Wintab 수집
- `native-bridge/bridge/WebSocketEventHub.cs`: 입력 큐를 각 WebSocket 클라이언트에 fan-out
- `native-bridge/bridge/WacomLocalBridge.csproj`: Windows 빌드와 embedded resource 설정

### SDK 사본

- `native-bridge/vendor/wacom/WacomMTDN`: Windows Wacom Multi-Touch .NET wrapper
- `native-bridge/vendor/wacom/WintabDN`: Windows Wintab .NET wrapper
- `native-bridge/vendor/wacom/WACOM-SDK-LICENSE.md`: SDK 관련 라이선스 및 출처 메모

### 레거시/진단 코드

- `native-bridge/Program.cs`
- `native-bridge/WacomInputProbe.csproj`
- `native-bridge/run-probe.cmd`
- `native-bridge/run-bridge.cmd`

루트 실행 파일을 만드는 실제 구현은 `native-bridge/bridge` 아래다. 레거시 probe를 macOS 제품 코드의 출발점으로 혼동하지 않는다.

## 4. 현재 데이터 흐름

```text
Wacom touch sensor
  -> Wacom driver
  -> WacomMT Observer callback
  -> NativeInputEvent
  -> bounded input queue (16,384)
  -> WebSocketEventHub
  -> per-client bounded queue (1,024)
  -> ws://127.0.0.1:8765/ws
  -> app.js
  -> requestAnimationFrame Canvas rendering

Wacom pen
  -> Wintab Digitizer context
  -> GetDataPackets polling
  -> same NativeInputEvent/WebSocket/render path

Mouse
  -> Chrome Pointer Events
  -> app.js directly
```

중요: 브라우저 Pointer Events는 **마우스에만** 사용한다. `handleMousePointer()`가 `pointerType === "mouse"`만 허용하는 것은 의도된 동작이다. 터치와 펜을 브라우저 Pointer Events로 다시 수집하면 네이티브 스트림과 중복되고, 팜리젝션·접점 소실·성능 문제를 정확히 관찰할 수 없게 된다.

## 5. WebSocket 프로토콜

서버 주소:

- HTTP: `http://127.0.0.1:8765`
- WebSocket: `ws://127.0.0.1:8765/ws`
- 상태: `GET /api/status`
- readiness: `GET /health`

연결 직후 첫 메시지는 `bridge.hello`, 프로토콜 버전은 현재 `1`이다.

이벤트 공통 필드:

```json
{
  "sequence": 1,
  "timestampUs": 0,
  "source": "wacommt | wintab | future-macos-source",
  "type": "touch.frame | pen.packet | pen.proximity",
  "deviceId": 0
}
```

### `touch.frame`

프레임 안의 모든 접점을 한 메시지로 보낸다.

```json
{
  "type": "touch.frame",
  "touch": {
    "frameNumber": 123,
    "contacts": [
      {
        "id": 1,
        "state": "WMTFingerStateDown | WMTFingerStateHold | WMTFingerStateUp | WMTFingerStateNone",
        "x": 0,
        "y": 0,
        "width": 0,
        "height": 0,
        "sensitivity": 0,
        "orientation": 0,
        "confidence": true
      }
    ]
  }
}
```

`Confidence === false`인 접점은 현재 UI에서 빨간색 계열 `#ff5d73`으로 표시한다. 정상 터치는 초록색 `#45d6a1`이다. 마커, 궤적, 데이터 카드와 범례가 같은 색상 분기를 사용한다.

### `pen.packet`

현재 프런트엔드는 Wintab 형태의 필드를 기대한다.

```json
{
  "type": "pen.packet",
  "pen": {
    "serial": 0,
    "cursor": 0,
    "x": 0,
    "y": 0,
    "z": 0,
    "pressure": 0,
    "tangentialPressure": 0,
    "buttons": 0,
    "azimuth": 0,
    "altitude": 0,
    "twist": 0,
    "status": 0,
    "changed": 0
  }
}
```

Windows 값은 azimuth/altitude/twist가 0.1도 단위이고 `app.js`가 10으로 나눈다. macOS `NSEvent.tilt`와 `rotation`은 표현 방식이 다르므로 다음 중 하나를 명시적으로 선택해야 한다.

1. macOS 값을 기존 Wintab 호환 단위로 변환해 프로토콜 1을 그대로 유지
2. 프로토콜을 확장해 정규화된 `tiltX`, `tiltY`, `rotation`을 추가하고 프런트엔드가 두 형식을 모두 처리

Windows 호환성을 깨지 않는 2번이 장기적으로 더 명확하지만, 첫 macOS probe에서는 원시 AppKit 값도 로그에 남겨 변환을 검증해야 한다.

### `pen.proximity`

```json
{
  "type": "pen.proximity",
  "proximity": {
    "hardware": true,
    "context": true
  }
}
```

macOS에는 Wintab의 context proximity와 정확히 같은 개념이 없으므로 `hardware`를 실제 `enteringProximity`에 대응하고, `context`는 호환 필드로 정의하거나 프로토콜을 확장한다. 의미를 문서화하고 Windows 프런트엔드를 깨지 않는다.

## 6. 성능상 중요한 현재 구현

초기 브라우저 기반 구현에서는 터치 2개와 펜이 동시에 들어올 때 프레임 드랍이 관찰됐다. 현재 구현에는 다음 방어가 들어 있다.

- 네이티브 callback에서 복잡한 작업을 하지 않고 데이터 복사 후 즉시 반환
- 전체 입력용 16,384 bounded channel, overflow 시 oldest drop
- WebSocket 클라이언트마다 1,024 bounded channel
- 느린 브라우저 하나가 네이티브 입력 수집을 막지 않음
- Canvas는 입력 이벤트마다 즉시 그리지 않고 `requestAnimationFrame`으로 coalescing
- 사이드 패널 DOM 갱신은 80ms 간격으로 throttle
- 궤적은 입력당 최대 64점
- 최근 이벤트 로그는 12개
- Wintab은 `WT_PACKET` 메시지에 의존하지 않고 `GetDataPackets(128, true, ...)`를 2ms idle 간격으로 polling
- `/api/status`에서 sequence, queue drop과 입력 카운터를 확인 가능

macOS에서도 callback 또는 전역 이벤트 monitor의 메인 스레드에서 JSON 직렬화, DOM 처리, 긴 로그 출력 등을 하지 않는다. 즉시 고정 크기 데이터로 복사하여 worker/queue로 넘긴다.

## 7. Windows에서 이미 해결한 문제와 교훈

### 터치 좌표 오프셋

초기 버전에서 실제 손가락보다 왼쪽 아래에 표시됐다. 현재는 장치 logical bounds를 화면 좌표로 변환하고, 브라우저 viewport의 화면상 원점과 Chrome 상단 프레임을 보정한다.

macOS에서는 기존 Windows 수식을 그대로 쓰지 않는다. 다음을 실제 장치에서 측정한다.

- AppKit/NSScreen의 좌하단 원점
- 브라우저의 좌상단 원점
- Retina backing scale과 CSS pixel
- Cintiq가 보조 모니터일 때의 음수/비주 모니터 좌표
- 메뉴 막대와 Dock의 available frame
- Chrome 창 프레임과 viewport 원점

### 사라지지 않는 터치 마크

`WMTFingerStateNone`은 즉시 삭제하고, Up은 짧게 표시한 뒤 제거한다. 현재 타이머는 다음과 같다.

- touch Up hold: 250ms
- touch stale: 500ms
- pen stale: 180ms

이전 브라우저 Pointer Events 프로토타입에는 팜리젝션 후 접점을 되살리기 위한 2초 후보 보관 실험이 있었지만, 현재 네이티브 WacomMT 제품 코드에는 그 후보 캐시가 존재하지 않는다. 과거 실험을 현재 동작으로 오해하지 않는다.

### 창 전환 후 펜 소실

Windows Wintab context가 Chrome과 다른 앱의 context에 가려지면서 펜 패킷이 멈췄다. 현재 해결책:

- 웹페이지가 `bridge.activate`/`bridge.deactivate`와 generation을 전송
- 활성화 후 0ms, 75ms, 200ms에 bounded `SetOverlapOrder(true)` 수행
- deactivate 시 예정된 승격 취소
- `WT_CTXOVERLAP`가 `CXS_OBSCURED`일 때 활성 브라우저가 있는 경우에만 50ms 후 승격
- generation으로 빠른 창 전환의 오래된 작업이 새 상태를 덮지 못하게 함
- 100ms rate limit과 2초당 3회 burst 제한

이 로직은 Wintab 전용이다. macOS에 그대로 복제하지 않는다. macOS에서 Chrome이 전면일 때는 AppKit의 global event monitor로 Chrome에 전달되는 tablet 이벤트를 관찰하고, 브리지 자체 이벤트를 위해 local monitor도 함께 설치하는 방식을 우선 검토한다. global monitor는 자기 앱 이벤트를 받지 않고 local monitor는 다른 앱 이벤트를 받지 않으므로 둘 다 필요하다.

Wacom macOS Driver Request Interface의 application-specific context는 앱이 background일 때 정지한다고 문서화되어 있으므로, Chrome이 전면인 이 도구의 주 펜 수집 경로로 단독 사용하지 않는다.

### 길게 누르기 컨텍스트 메뉴

입력 영역에는 이미 `touch-action: none`과 `user-select: none`이 있다. Chrome의 길게 누르기 `contextmenu`는 별도이므로 다음 코드도 존재한다.

```js
inputArea.addEventListener("contextmenu", event => event.preventDefault());
```

입력 영역에서 메뉴만 막고 마우스 오른쪽 버튼 원시 시각화는 유지한다.

## 8. 팜리젝션 관련 실제 관찰

과거 Windows 테스트에서 다음을 관찰했다.

- 3개 이상의 터치가 유지되는 도중 펜이 없었다가 hover로 접근하면 모든 브라우저 터치가 사라지는 경우가 있었다.
- 브라우저 이벤트 로그는 각 접점의 `up`, `leave`가 나온 뒤 `pen move`가 들어오는 순서였다.
- Unity 프로젝트에서는 펜이 사라진 후 물리적으로 계속 누르고 있던 터치가 다시 감지되기도 했다.
- Unity에서는 펜이 기울어진 손 방향의 터치를 주로 무시하고 반대편 터치는 유지하는 양상이 있었다.
- 일반 웹 Pointer Events에서는 펜 주위의 큰 원형 반경처럼 터치가 제거되는 양상이 있었다.
- 이 차이는 앱 레벨보다는 Wacom 드라이버/펌웨어 및 사용하는 입력 API 경로의 차이로 판단했다.

현재 앱은 WacomMT Observer callback에서 받은 접점을 앱에서 임의로 팜리젝션하지 않는다. `Confidence`도 드라이버가 계산한 bool을 그대로 전달한다. `false`는 시각적으로만 빨간색으로 구분하고 자동 제거하지 않는다.

macOS에서도 앱 임의의 거리 기반 팜리젝션을 먼저 추가하지 않는다. 우선 WacomMultiTouch callback이 실제로 보내는 접점과 confidence를 그대로 기록하여 Windows와 비교한다.

필수 재현 테스트:

1. 터치 1~최대 개수까지 순차 입력
2. 3개 터치를 유지한 채 펜을 멀리서 hover로 진입
3. hover 중 펜 기울기 방향과 반대 방향에 각각 터치
4. 펜을 proximity 밖으로 제거했을 때 유지 중인 터치가 다시 나타나는지 확인
5. 다시 나타난 접점의 ID가 유지되는지 새 ID인지 확인
6. 각 단계에서 `Confidence`, width, height, sensitivity, orientation 기록

## 9. macOS API 대응안

### 터치

Wacom 드라이버가 설치하는 `WacomMultiTouch.framework`를 사용한다.

- `WacomMTInitialize`
- attach/detach callback
- `WacomMTGetDeviceCapabilities`
- `WacomMTRegisterFingerReadCallback`
- `WMTProcessingModeObserver`
- `WacomMTQuit`

Wacom 문서상 데이터 구조와 `Confidence` 의미는 Windows와 동일한 계열이다. Swift에서 프레임워크를 직접 쓰기보다 C 또는 Objective-C wrapper가 필요할 수 있다. 공식 macOS Multi-Touch 샘플을 먼저 확보하고, 필요한 headers/wrapper를 `native-bridge/macos/vendor/wacom` 같은 프로젝트 내부 경로로 복사한다.

드라이버가 설치한 `WacomMultiTouch.framework`는 런타임에 동적으로 로드하며 앱 번들에 임의 복사하지 않는다.

공식 참고:

- <https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-overview/>
- <https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-basics/>
- <https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-reference/>
- <https://developer-docs.wacom.com/docs/icbt/macos/sample-code/sc-mac-multi-touch/>

### 펜

Windows Wintab 대신 AppKit `NSEvent`를 사용한다.

관찰할 이벤트:

- `.tabletProximity`
- `.tabletPoint`
- mouse moved/down/up/dragged 중 `.tabletPoint` subtype인 이벤트

필요한 값:

- `absoluteX`, `absoluteY`, 필요 시 `absoluteZ`
- `pressure`
- `tangentialPressure`
- `tilt`
- `rotation`
- `buttonMask`
- `enteringProximity`
- `pointingDeviceType`로 pen/eraser 구분
- device/tablet/unique identifiers

Apple 문서가 권장하듯 tablet event는 native tablet event와 mouse event subtype 양쪽으로 올 수 있으므로 두 경로를 모두 처리한다.

Chrome이 전면인 상태에서도 수집하기 위해:

- `NSEvent.addGlobalMonitorForEvents`로 다른 앱 대상 이벤트 관찰
- `NSEvent.addLocalMonitorForEvents`로 자기 앱 대상 이벤트 관찰
- 동일 이벤트가 두 번 들어오지 않는지 serial/timestamp/eventNumber 기반으로 검증
- monitor callback에서는 즉시 queue에 넣고 반환

공식 참고:

- <https://developer.apple.com/documentation/appkit/nsevent>
- <https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29>
- <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTabletEvents/HandlingTabletEvents.html>
- <https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-basics/>

## 10. macOS 권한과 패키징

목표 실행 형태는 `WacomInputTest.app` 하나를 실행하면 localhost 브리지가 시작되고 Chrome에서 페이지가 열리는 것이다.

확인할 항목:

- Apple Silicon(`arm64`)과 대상 맥의 실제 아키텍처
- Xcode/Command Line Tools
- 최신 Wacom macOS 드라이버
- Cintiq Pro가 Wacom Center와 일반 앱에서 정상 동작하는지
- WacomMultiTouch framework 설치 위치와 로드 가능 여부
- AppKit global monitor 사용 시 macOS Input Monitoring/Accessibility 권한 요구 여부
- Hardened Runtime 사용 여부
- Wacom 문서의 Mach service temporary exception entitlements
- unsigned 로컬 앱과 서명된 `.app`에서 동작 차이

Wacom 문서에 나온 서비스 이름을 entitlement에 사용할 때 임의로 생략하거나 변경하지 말고, 현재 설치된 드라이버와 샘플 프로젝트에서 재확인한다.

Chrome 실행은 Windows 경로 탐색 대신 `NSWorkspace.shared.open(...)`, Launch Services 또는 `/usr/bin/open -a "Google Chrome" URL`에 해당하는 네이티브 방식을 사용한다. Chrome이 없을 때는 기본 브라우저 fallback과 직접 접속 URL을 출력한다.

서버는 계속 `127.0.0.1`에만 바인딩하고 외부 인터페이스 `0.0.0.0`에는 열지 않는다.

## 11. 권장 소스 구조

Windows 버전을 깨지 않고 다음처럼 분리하는 것이 목표다. 실제 이름은 구현 중 조정할 수 있다.

```text
WebTest/
  web/ 또는 현재 루트 web assets
    index.html
    app.js
    styles.css
  native-bridge/
    shared/
      protocol models
      WebSocket hub/server
    windows/
      현재 WacomMTDN + Wintab 구현
      vendor/wacom/
    macos/
      AppKit/WacomMultiTouch 구현
      vendor/wacom/
  dist/
    windows/WacomInputTest.exe
    macos/WacomInputTest.app
```

큰 구조 변경 전에는 먼저 macOS probe로 다음 네 가지를 증명한다.

1. WacomMultiTouch callback에서 실제 접점과 confidence 수신
2. Chrome이 전면인 상태에서 pen hover/proximity/pressure/tilt/button 수신
3. touch + pen 동시 수신 시 packet/frame 누락과 프레임 드랍이 없음
4. Cintiq 좌표가 Chrome Canvas 위치와 일치

그 뒤 기존 WebSocket 프로토콜에 연결한다.

## 12. 프런트엔드 호환 시 주의점

현재 `app.js`는 상태 응답에서 다음 Wintab 이름을 직접 참조한다.

- `native.wintabX`
- `native.wintabY`
- `native.wintabMaxPressure`
- Wintab overlap/promotion 진단 카운터

macOS에서 선택지는 두 가지다.

- 초기 호환 구현: 같은 필드에 macOS axis/pressure 값을 채우고 Windows 전용 카운터는 0으로 둠
- 정식 정리: `penX`, `penY`, `penMaxPressure` 같은 공통 필드를 추가하고 프런트엔드가 공통 필드를 우선 사용하며 Wintab 필드로 fallback

후자를 권장하지만 프로토콜 버전과 Windows 실행을 함께 검증한다. UI 문구의 `WacomMT + Wintab`도 플랫폼 중립적인 `Wacom native touch + pen`으로 바꾸되 Windows 동작을 손상시키지 않는다.

터치 state 문자열은 현재 Wacom enum 이름에 결합되어 있다. macOS WacomMultiTouch가 같은 enum 이름을 제공하지 않더라도 WebSocket에는 기존 문자열을 보내거나, `down/hold/up/none` 공통 enum을 프로토콜 2로 추가해 양 플랫폼을 지원한다.

## 13. 완료 기준

### 기능

- 앱 하나로 브리지 시작 및 Chrome 자동 실행
- 마우스 위치·버튼 시각화
- 장치가 보고하는 최대 touch 수까지 접점별 추적
- touch ID/state/좌표/크기/sensitivity/orientation/confidence 표시
- confidence false 접점 빨간색 표시
- pen hover, proximity, 접촉, 압력, 버튼, tilt, rotation, eraser 표시
- touch와 pen 동시 입력
- `C` 초기화, `F` 전체화면
- 입력 영역 long-press 컨텍스트 메뉴 억제

### 안정성

- Chrome과 다른 창 사이를 빠르게 반복 전환해도 pen이 영구 소실되지 않음
- 2개 이상의 touch + pen에서 눈에 띄는 프레임 드랍 없음
- touch Up/None 이후 마커가 남지 않음
- pen proximity out 이후 마커가 남지 않음
- 느린/끊어진 WebSocket 클라이언트가 입력 callback을 막지 않음
- 앱 종료 시 callback, monitors, WebSocket과 driver framework가 정리됨

### 좌표

- Cintiq 네 모서리와 중앙에서 손가락·펜 위치가 Canvas와 일치
- Retina 배율 변화 후 일치
- Cintiq가 주/보조 모니터인 경우 모두 일치
- Chrome 창 이동·크기 변경·전체화면 이후 일치

### 진단

- `/health`에 touch/pen readiness
- `/api/status`에 장치 capabilities와 event/drop counters
- WebSocket sequence gap 표시
- raw 값과 정규화/표시 값 모두 확인 가능

## 14. 하지 말아야 할 것

- 터치와 펜을 다시 브라우저 Pointer Events만으로 구현하지 않는다.
- Wacom 드라이버의 confidence false 접점을 앱에서 자동 삭제하지 않는다.
- 펜 위치 기준의 임의 원형 팜리젝션을 먼저 추가하지 않는다.
- callback 또는 AppKit monitor에서 직접 WebSocket send/DOM 수준의 무거운 처리를 하지 않는다.
- macOS SDK 파일을 Downloads 또는 시스템 외부 경로에 둔 채 프로젝트가 그 절대 경로를 참조하게 하지 않는다.
- Windows vendor 파일을 macOS 파일로 덮어쓰지 않는다.
- 좌표계가 Windows와 같다고 가정하지 않는다.
- Wacom DRI application context가 background에서도 동작한다고 가정하지 않는다.
- 실제 Cintiq 테스트 없이 "동작 완료"로 판단하지 않는다.

## 15. 첫 작업 순서

1. 이 문서와 실제 코드 전체를 읽는다.
2. 맥 모델, CPU 아키텍처, macOS 버전, Xcode, Chrome, Wacom 드라이버, Cintiq 모델을 확인한다.
3. Wacom 공식 macOS Multi-Touch 샘플과 headers를 확보해 프로젝트 내부에 복사한다.
4. 최소 터치 probe를 만들어 callback/capabilities/confidence를 콘솔에서 확인한다.
5. 최소 AppKit pen probe를 만들어 Chrome 전면 상태의 global/local 이벤트를 확인한다.
6. 좌표와 필드 단위를 원시 로그로 정리한다.
7. 두 probe를 동시에 실행해 동시 입력과 성능을 확인한다.
8. 공통 프로토콜/서버에 연결한다.
9. 기존 웹 UI를 플랫폼 중립적으로 보완한다.
10. `.app` 패키징, 권한, Chrome 자동 실행을 적용한다.
11. 완료 기준 전체를 실제 장치에서 검증한다.

## 16. 현재 구현의 핵심 원칙 한 줄 요약

**브라우저는 표시만 담당하고, 터치와 펜의 원형에 가까운 데이터는 OS별 네이티브 API에서 빠르게 수집한 뒤 동일한 localhost WebSocket 프로토콜로 전달한다.**
