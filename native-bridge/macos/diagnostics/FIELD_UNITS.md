# macOS 좌표 및 원시 필드 단위

작성일: 2026-08-15  
대상 장치: Cintiq Pro 24 Touch, Wacom 드라이버 6.4.13-4

이 문서는 macOS 네이티브 입력 필드 조사 결과다. 값은 가능한 한 변환하지 않은
원시 값과 화면 표시용 값을 함께 보존한다.

## 1. 테스트 당시 화면 배치

`NSScreen` 결과:

| 화면 | AppKit `frame` | 배율 |
| --- | --- | --- |
| Built-in Retina Display | `(0, 0, 1512, 982)` | `2.0` |
| CintiqPro24PT | `(-193, 982, 1920, 1080)` | `2.0` |

AppKit의 화면 좌표는 아래쪽 원점을 사용한다. 같은 Cintiq를 Wacom Multi-Touch와
Core Graphics 이벤트 좌표로 보면 `(-193, -1080, 1920, 1080)`이며, 주 화면의 왼쪽
위가 원점이고 위쪽에 배치된 Cintiq의 Y가 음수다.

따라서 이 배치에서 Cintiq 내부의 표시 좌표는 다음과 같다.

```text
localX = screenX + 193
localY = screenY + 1080
normalizedX = localX / 1920
normalizedY = localY / 1080
```

이 상수는 현재 배치에만 유효하다. 실제 브리지에서는 실행 중 얻은 Cintiq 화면의
원점과 크기를 사용해야 한다. `backingScaleFactor=2`는 Canvas backing store 크기를
정할 때 사용하고, 논리 화면 좌표 자체를 임의로 2로 나누지 않는다.

## 2. 터치 좌표 표본

Wacom 장치 capability:

```text
device=0 type=integrated
logical=(-193,-1080,1920,1080)
physicalMm=(522.4,293.9)
reported=(26640,14988)
scan=(1,1)
fingerMax=10
flags=0x0
```

각 제스처의 첫 `down` 표본:

| 위치 | 원시 X/Y | Cintiq 정규화 X/Y |
| --- | --- | --- |
| 왼쪽 위 | `(-165.396, -1028.479)` | `(0.01438, 0.04770)` |
| 오른쪽 위 | `(1700.477, -1016.950)` | `(0.98619, 0.05838)` |
| 오른쪽 아래 | `(1695.865, -8.575)` | `(0.98378, 0.99206)` |
| 왼쪽 아래 | `(-167.703, -9.440)` | `(0.01318, 0.99126)` |
| 중앙 | `(798.784, -497.198)` | `(0.51655, 0.53963)` |

결론: 통합형 장치의 `WacomMTFinger.X/Y`는 Cintiq의 로컬 좌표가 아니라 전역 데스크톱
논리 좌표다. 이 테스트에서는 Core Graphics 펜 화면 좌표와 축, 원점, 단위가 직접
일치했다.

### 터치 필드

| 필드 | 의미/단위 | 이번 장치의 관찰 |
| --- | --- | --- |
| `FrameNumber` | 드라이버 프레임 번호 | 제스처마다 `1`부터 다시 시작하는 양상 |
| `FingerID` | 접점 수명 동안 사용할 불투명 ID | 한 손가락은 `0`, 두 번째는 `1`; 문서의 1 시작 설명과 실제 값이 다르므로 산술 의미를 부여하지 않음 |
| `TouchState` | `down`, `hold`, `up` 상태 enum | 세 상태 모두 확인 |
| `X`, `Y` | 전역 데스크톱 논리 좌표 | Cintiq 범위 `[-193,1727) × [-1080,0)` |
| `Width`, `Height` | X/Y와 같은 논리 좌표 단위의 접촉 크기 | `(16.613,16.610)`, `(33.225,33.219)` 두 단계 관찰 |
| `Sensitivity` | 압력이 아닌 접촉 강도 원시 정수 | 모든 1,219 접점에서 `0`; capability flag에도 sensitivity 지원이 없었음 |
| `Orientation` | 접촉 타원의 방향(도) | 모든 접점에서 `0.000`; 이번 장치/경로에서는 유효값 미확인 |
| `Confidence` | 드라이버가 접촉을 의도된 손가락으로 판단했는지 나타내는 bool | 모든 접점에서 `true`; `false`도 전달은 유지해야 함 |

`Sensitivity`는 압력으로 정규화하지 않는다. `Confidence=false`도 제거하지 않고 원문 그대로
전달한다.

## 3. 펜 좌표 표본

보강된 probe는 두 좌표를 동시에 기록한다.

- `absolute=(x,y,z)`: AppKit의 태블릿 원시 절대 좌표
- `screen=(x,y)`: 같은 `NSEvent`의 `CGEventGetLocation` 전역 논리 화면 좌표

| 위치 | `absoluteX/Y/Z` | `screenX/Y` |
| --- | --- | --- |
| 왼쪽 위 | `(316, 1063, 0)` | `(-180.473, -1005.359)` |
| 오른쪽 아래 | `(52202, 15376, 0)` | `(1710.914, -14.551)` |

전체 보완 로그의 421개 point event를 선형 회귀하면 다음 관계가 나왔다. 이는 현재 화면
배치/드라이버 매핑의 관찰값이지 고정 프로토콜 상수가 아니다.

```text
screenX = 0.036455821917 * absoluteX - 192.401382
screenY = 0.069221130193 * absoluteY - 1078.940920
```

표시에는 이벤트가 이미 제공하는 `screen`을 사용하고, `absolute`는 진단 및 원형 보존용으로
함께 전달한다. 디스플레이 배치나 Wacom 매핑이 바뀌면 위 회귀 상수는 달라질 수 있으므로
브리지에서 하드코딩하지 않는다.

### 펜 필드

| 필드 | 의미/단위 | 이번 장치의 관찰 |
| --- | --- | --- |
| `absoluteX/Y` | 전체 태블릿 해상도의 장치 절대 좌표 | 정수처럼 양자화됨; 화면 좌표 변환 상수를 가정하지 않음 |
| `absoluteZ` | 장치 절대 Z/근접 거리 원시값 | 접촉 시 `0`, 호버에서 최대 `1023` 관찰 |
| `screenX/Y` | Core Graphics 전역 논리 화면 좌표 | 터치 X/Y와 직접 일치하는 좌표계 |
| `pressure` | 정규화 압력 | `0.0` 호버, 접촉에서 양수, 전체 관찰 범위 `0.0...1.0` |
| `tangentialPressure` | 배럴 방향 압력 `[-1,1]` | 전 이벤트 `0.0`; 이 펜에서 유효값 미확인 |
| `tiltX/Y` | 축별 기울기 `[-1,1]` | X `-0.9063...0.8594`, Y `-0.9063...0.9062` 확인 |
| `rotation` | 펜 축 회전 각도(도) | 전 이벤트 `0.0`; 이 펜에서 유효값 미확인 |
| `buttonMask` | tip/사이드 버튼 비트 마스크 | tip `0x1`, 앞쪽 버튼 `0x2`, 뒤쪽 버튼 `0x4` 확인 |
| `pointingDeviceType` | proximity 장치 종류 | `pen`, `eraser` 확인 |
| `uniqueID` | 펜 끝별 64-bit 식별값 | pen `79448682544951`, eraser `220220530638647` |

Apple 정의상 tilt X는 왼쪽이 음수/오른쪽이 양수이고, tilt Y는 위쪽이 음수/아래쪽이
양수이며 수직은 `(0,0)`이다.

사이드 버튼 `0x2`는 호버 중에도 mouse down/drag 이벤트의 `pressure=1.0`을 만들었다.
따라서 `pressure>0`만으로 펜촉 접촉을 판정하면 안 된다. `buttonMask & 0x1`, mouse event
종류와 proximity 상태를 함께 사용해야 한다. `0x4`는 이번 설정에서 pressure `0.0`인 짧은
left mouse down/up 쌍으로 들어왔다.

## 4. proximity 중복

동일한 proximity 변화가 거의 같은 timestamp로 다음 두 형태로 함께 들어왔다.

1. native `tabletProximity`, subtype `0`
2. mouse event, subtype `tabletProximity(2)`

point event도 native tablet event 또는 mouse event의 `tabletPoint(1)` subtype으로 올 수 있다.
서버 단계에서는 event timestamp, device ID, entering flag, unique ID 등을 이용해 동일 이벤트를
중복 전송하지 않도록 해야 한다.

## 5. 원시 로그와 재현 도구

- `raw/screen-info.log`: 화면 frame과 Retina 배율
- `raw/touch-coordinate-run.log`: 693 frames, 1,219 contacts, drop 0
- `raw/pen-coordinate-run.log`: point 785, proximity 31, queue drop 0
- `raw/pen-screen-button-eraser-run.log`: 화면 좌표, 버튼 2종, pen/eraser 식별
- `screen-info.swift`: 화면 배치를 다시 기록하는 도구

## 6. 공식 정의 참고

- Wacom Multi-Touch Framework Reference: <https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-reference/>
- Apple `NSEvent`: <https://developer.apple.com/documentation/appkit/nsevent>
- Apple Handling Tablet Events: <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTabletEvents/HandlingTabletEvents.html>
- Apple `absoluteX`: <https://developer.apple.com/documentation/appkit/nsevent/absolutex>
- Apple `pressure`: <https://developer.apple.com/documentation/appkit/nsevent/pressure>
- Apple `tilt`: <https://developer.apple.com/documentation/appkit/nsevent/tilt>
- Apple `buttonMask`: <https://developer.apple.com/documentation/appkit/nsevent/buttonmask-swift.property>
