# macOS 최종 실제 장치 검증

검증일: 2026-08-15  
대상 장치: Cintiq Pro 24 Touch  
최종 패키지: `dist/macos/WacomInputTest.app`

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
