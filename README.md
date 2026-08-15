# Wacom Native Input Monitor

macOS 버전 구현을 이어받을 때는 먼저 [MACOS_HANDOFF.md](MACOS_HANDOFF.md)를 읽으세요.

Windows와 macOS의 Wacom Cintiq Pro 네이티브 입력을 기본 브라우저에서 시각화하는
로컬 테스트 앱입니다.

브라우저 Pointer Events가 아니라 다음 네이티브 입력을 localhost WebSocket으로 받아 표시합니다.

- 터치: WacomMT Observer callback
- 펜: Wintab Digitizer context
- 전달: `ws://127.0.0.1:8765/ws`

## 실행

Windows의 `WacomInputTest.exe` 또는 macOS의 `WacomInputTest.app`을 실행하면 브리지가
시작되고 시스템 기본 브라우저에서
<http://127.0.0.1:8765>가 자동으로 열립니다. 웹 화면은 실행 파일 안에
포함되어 있으므로 다른 파일을 함께 복사할 필요가 없습니다.

브리지 창을 닫으면 입력 수집과 웹 서버가 함께 종료됩니다.

## 화면에 표시되는 데이터

- 최대 10개 터치의 ID, Down/Hold/Up, 원시 좌표, 접촉 크기, 감도, 방향, 신뢰도
- 펜 호버/접촉, 버튼 비트, 압력, 방위각, 고도각, 트위스트, Z, 지우개 상태
- 브리지 연결 상태, 이벤트 sequence, 브라우저 수신 누락 수

터치와 펜 좌표는 각 장치의 네이티브 축 범위를 캔버스 전체에 맞춰 표시합니다.
`C`는 화면 초기화, `F`는 전체 화면 전환입니다.
