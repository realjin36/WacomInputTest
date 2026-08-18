# macOS 최종 실제 장치 검증

대상 장치: Cintiq Pro 24 Touch  
현재 패키지: `dist/macos/WacomNativeBridge.app`

## 2026-08-18 브리지·예제 분리 회귀 검증

- Apple Silicon 앱 빌드 및 ad-hoc 코드 서명 검증 통과
- 앱 번들에 HTML, JavaScript, CSS 및 `Contents/Resources/Web`이 없음을 확인
- `GET /`가 protocol 2 서비스 설명 JSON을 반환
- `/index.html`이 `404`를 반환
- loopback Origin과 `--allowed-origin`의 CORS 응답 확인
- 허용되지 않은 Origin의 `403` 거부 확인
- Origin 없는 네이티브 WebSocket 클라이언트의 protocol 2 hello 확인
- GUI 실행 시 상태 창만 열리고 브라우저가 자동 실행되지 않음을 사용자 확인
- 상태 창의 종료 버튼으로 서버와 앱이 정상 종료됨을 사용자 확인

18초 실제 입력 WebSocket 캡처:

- 수신 이벤트: 1,339, sequence `1..1339`, gap `0`
- touch frames/contacts: `1,006 / 5,325`, 최대 동시 touch `8`
- pen packets: `332`, 양의 압력 packet `321`
- proximity messages: `1`
- invalid messages: `0`
- 서버 전체 produced/broadcast: `1,619 / 1,619`
- input/client drop: `0 / 0`
- truncated touch frames: `0`

### 독립 예제 웹 모니터

- 브리지와 `examples/web-monitor/server.mjs`를 별도 프로세스로 실행
- 기본 구성 `monitor :8080` → `bridge :8765` 연결 확인
- 브리지 연결 상태, Touch/Pen readiness, 터치·펜·동시 입력 시각화 확인
- 브라우저 탭 종료 후 브리지와 예제 서버가 각각 계속 실행됨을 확인
- 예제 서버만 종료해도 브리지가 계속 동작함을 확인
- `--port 9876` 브리지와 `?bridge=http://127.0.0.1:9876` 주소 재정의 연결 확인
- 예제 서버 종료 후 사용자 지정 포트 브리지가 계속 동작함을 확인
- 최종 종료 후 포트 `8080`과 `9876`이 모두 닫힘을 확인

## 2026-08-15 전체 기능 기준선

## 자동 검증

- 실행 파일: Apple Silicon `arm64`
- ad-hoc code signature, Hardened Runtime, App Sandbox 서명 검증 통과
- loopback 전용 HTTP `127.0.0.1:8765` 및 WebSocket protocol 2 handshake 통과
- `/health`: touch/pen ready
- `/api/status`: 장치 capabilities, 좌표계, event/drop counters 확인
- 앱 종료 후 localhost 서버 연결 종료 확인

최종 실제 장치 실행의 종료 직전 카운터:

- produced/broadcast events: 19,963 / 19,963
- touch frames/contacts: 13,299 / 57,807
- pen packets/proximity: 6,603 / 61
- input dropped: 0
- truncated touch frames: 0
- client messages dropped: 0

## 실제 장치 기능 및 안정성

사용자 확인 결과 모두 통과:

- 마우스 위치와 버튼
- 최대 10개 멀티터치의 접점별 ID/state/좌표/크기/confidence
- confidence false 접점의 구분 표시
- pen hover/proximity/contact/pressure/button/tilt/rotation/eraser
- 2개 이상의 touch와 pen 동시 입력
- touch Up/None 및 pen proximity out 이후 마커 정리
- 브라우저와 다른 창을 빠르게 전환한 뒤 pen 입력 복구
- long-press context menu 억제
- `C` 초기화와 `F` 전체화면

## 좌표

사용자 확인 결과 다음 조건에서 손가락과 펜의 네 모서리 및 중앙 좌표가 Canvas와 일치했다.

- Cintiq 창 위치 및 크기 변경
- 전체화면 진입과 종료
- Cintiq 해상도/Retina 배율 변경
- Cintiq를 주 디스플레이와 보조 디스플레이로 각각 사용
- 테스트 후 원래 디스플레이 설정으로 복구

화면 배치나 배율 값은 제품에 하드코딩하지 않고 런타임 전역 논리 좌표로 변환한다.

## 알려진 고부하 한계

6개 touch와 pen을 동시에 사용할 때 pen 시각화가 약 1초, 8개 touch와 pen에서는 약 2초
늦어지는 현상이 관찰됐다. 이 조건은 실제 프로젝트 요구 범위 밖이므로 이번 완료를 막지 않는
알려진 한계로 기록한다.

입력 및 클라이언트 drop은 0이므로 주원인은 손실보다 FIFO/WebSocket/브라우저 처리 경로의
백로그로 추정한다. 필요할 경우 단계별 queue-depth/latency 계측 후 touch hold 프레임 병합,
pen 우선순위, 브라우저 접점별 타이머 제거로 개선한다.
