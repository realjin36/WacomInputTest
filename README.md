# Wacom Native Input Monitor

macOS 버전 구현을 이어받을 때는 먼저 [MACOS_HANDOFF.md](MACOS_HANDOFF.md)를 읽으세요.

Windows와 macOS의 Wacom Cintiq Pro 네이티브 입력을 기본 브라우저에서 시각화하는
로컬 테스트 앱입니다.

브라우저 Pointer Events가 아니라 다음 네이티브 입력을 localhost WebSocket으로 받아 표시합니다.

- 터치: WacomMT Observer callback
- 펜: Wintab Digitizer context
- 전달: `ws://127.0.0.1:8765/ws`

## 실행

Windows의 `dist/windows/WacomInputTest.exe` 또는 macOS의
`dist/macos/WacomInputTest.app`을 실행하면 브리지가 시작되고 시스템 기본 브라우저에서
<http://127.0.0.1:8765>가 자동으로 열립니다. 웹 화면은 실행 파일 안에
포함되어 있으므로 다른 파일을 함께 복사할 필요가 없습니다.

브리지 창을 닫으면 입력 수집과 웹 서버가 함께 종료됩니다.

Windows 배포본은 Wacom 드라이버가 설치된 Windows x64 환경을 대상으로 합니다.
.NET 런타임은 실행 파일에 포함되어 있어 별도로 설치할 필요가 없습니다. 저장소 루트의
`WacomInputTest.exe`는 포팅 전 기준 파일이므로 최종 배포에 사용하지 않습니다.

## Windows 빌드와 테스트

개발 환경에는 .NET 10 SDK와 Node.js가 필요합니다. Windows PowerShell에서 실행합니다.

```powershell
.\native-bridge\test-windows.ps1
.\native-bridge\build-windows.ps1
```

빌드 스크립트는 자동 회귀 테스트를 먼저 실행한 뒤 x64 단일 실행 파일과 SHA-256 파일을
`dist/windows`에 생성합니다. 최종 검증 결과와 배포 정보는
[`native-bridge/WINDOWS_RELEASE.md`](native-bridge/WINDOWS_RELEASE.md)에 기록되어 있습니다.

## 화면에 표시되는 데이터

- 최대 10개 터치의 ID, Down/Hold/Up, 원시 좌표, 접촉 크기, 감도, 방향, 신뢰도
- 펜 호버/접촉, 버튼 비트, 압력, 방위각, 고도각, 트위스트, Z, 지우개 상태
- 브리지 연결 상태, 이벤트 sequence, 브라우저 수신 누락 수

터치와 펜 좌표는 각 장치의 네이티브 축 범위를 캔버스 전체에 맞춰 표시합니다.
`C`는 화면 초기화, `F`는 전체 화면 전환입니다.
