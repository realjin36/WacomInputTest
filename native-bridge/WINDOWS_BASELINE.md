# Windows 앱 포팅 기준선

확인일: 2026-08-15

## 목표

기존 Windows 네이티브 입력 구현을 유지하면서 현재 macOS 앱과 같은 제품 수준의 상태 창,
기본 브라우저 실행, 정상 종료 및 배포 경험을 제공한다. 최종 산출물은
`dist/windows/WacomInputTest.exe`로 고정한다. 실제 Windows+Cintiq 검증 전에는 저장소
루트의 기존 `WacomInputTest.exe`를 덮어쓰지 않는다.

## 현재 Windows 구현

- 프로젝트: `bridge/WacomLocalBridge.csproj`
- 런타임: `.NET 10`, `net10.0-windows`, Windows x64
- 호스트: ASP.NET Core/Kestrel, `127.0.0.1:8765` 전용
- 터치: 드라이버의 `WacomMT.dll`, Observer finger callback
- 펜: 드라이버의 `Wintab32.dll`, private digitizer context와 polling/message 처리
- 웹 리소스: 루트 `index.html`, `app.js`, `styles.css`를 publish 시 embedded resource로 포함
- 프로토콜: Windows protocol 1 (`touch.frame`, `pen.packet`, `pen.proximity`)
- 버퍼: 입력 16,384개 drop-oldest, WebSocket 클라이언트별 1,024개 drop-oldest
- 종료 정리: Wintab context close, WacomMT callback unregister/quit 및 WebSocket dispose 코드 존재

Wacom C# wrapper 소스는 `vendor/wacom/WacomMTDN`과 `vendor/wacom/WintabDN`에 포함되어
있다. 네이티브 `WacomMT.dll`과 `Wintab32.dll`은 제품에 복사하지 않고 설치된 Wacom
드라이버에서 로드한다.

## 현재 공통 UI 호환성

최신 `app.js`는 macOS 공통 필드를 우선 사용하면서 Windows의 다음 protocol 1 필드로
fallback한다.

- `native.wintabX`, `native.wintabY`
- `native.wintabMaxPressure`
- Wintab overlap/promotion counters
- 기존 WacomMT state 문자열
- 기존 Wintab pressure/orientation/status/button 값

따라서 Windows 프로토콜을 즉시 변경하지 않아도 최신 웹 UI를 사용할 수 있다. 빌드 시
루트 웹 파일을 다시 embed해야 하며, 2026-08-14에 생성된 기존 실행 파일에는
2026-08-15의 최신 `app.js`와 `index.html` 변경이 포함되어 있지 않다.

## 기존 실행 파일 기준

- 루트 `WacomInputTest.exe`: PE32+ console, x86-64, 317,257 bytes
- `single-file/WacomInputTest.exe`: 위 파일과 SHA-256 동일
- SHA-256: `c167f6248064b417db136db1dad349a14654435d57473f3c2964ee48074a20cf`
- 현재 결과물은 콘솔 애플리케이션이며 제품용 상태 창이 없다.

## macOS 앱과의 차이

1. Windows 호스트는 콘솔 애플리케이션이다.
2. Touch/Pen 상태와 event/drop counters를 보여주는 작은 GUI가 없다.
3. 브라우저 열기 및 정상 종료 버튼이 없다.
4. Chrome 설치 경로를 먼저 탐색하며 시스템 기본 브라우저를 직접 사용하지 않는다.
5. GUI 종료 요청과 ASP.NET/Wacom 자원 정리를 연결하는 명시적 수명주기가 없다.
6. 제품용 아이콘, WinExe 출력, 재현 가능한 `dist/windows` 빌드 스크립트가 없다.

## 다음 구현의 고정 원칙

- 기존 `WacomNativeInputSource`의 WacomMT/Wintab 동작은 기능상 필요한 경우가 아니면 수정하지 않는다.
- WinForms를 사용한다. 프로젝트에 이미 `UseWindowsForms=true`가 설정되어 있다.
- GUI 스레드에서 Wacom callback, WebSocket send 또는 서버 blocking 작업을 수행하지 않는다.
- 상태 창 종료, 닫기 버튼, `Alt+F4`를 하나의 cancellation/cleanup 경로로 연결한다.
- 브라우저는 `UseShellExecute=true`로 Windows 기본 브라우저에서 연다.
- 자동 테스트용 headless 옵션과 일반 GUI 실행을 분리한다.
- protocol 1 호환성을 유지하고 공통 UI의 Windows fallback을 실제 장치에서 회귀 검증한다.

## 현재 환경 제약

현재 macOS 작업 환경에는 `dotnet` SDK가 설치되어 있지 않다. 소스 작성과 정적 검토는
가능하지만 Windows WinForms 빌드 및 Wacom native runtime 검증은 Windows x64 장치에서
수행해야 한다. 빌드 단계가 준비되면 사용자에게 Windows에서 실행할 명령과 확인할 결과를
요청한다.

## 2단계 Windows 검증 결과

검증일: 2026-08-15  
검증 환경: Windows x64 + Wacom Cintiq

- `WacomLocalBridge.csproj` Release/win-x64 빌드 성공
- 새 `BridgeRuntime`, `BridgeOptions`, `BridgeStatus` 컴파일 성공
- headless 실행 옵션 `--no-window --no-browser --duration 5` 정상 처리
- `http://127.0.0.1:8765` Kestrel 시작 성공
- Touch ready: `True`
- Pen ready: `True`
- 5초 후 Application shutdown 및 summary 출력 확인
- 종료 시 input/WebSocket drop: 0/0

빌드 출력의 경고는 `vendor/wacom/WacomMTDN`과 `vendor/wacom/WintabDN`의 기존 nullable
annotation 및 analyzer 경고다. 이번 수명주기 분리 코드에서는 컴파일 경고나 오류가
보고되지 않았다. 공식 vendor 사본은 이 단계에서 수정하지 않는다.

## 6단계 Windows 배포 빌드 검증 결과

검증일: 2026-08-18

검증 환경: Windows x64 + Wacom Cintiq, .NET SDK 10.0.400

- `native-bridge/build-windows.ps1` Release 빌드 성공
- self-contained, compressed single-file `dist/windows/WacomInputTest.exe` 생성 성공
- 산출물 크기: 60.74 MiB
- SHA-256: `de21bc135fbbd4ceeb4988e1006a98a41b8b15a47dda72a989cad0fff3436c0e`
- PE machine x64(`0x8664`) 및 Windows GUI subsystem(`2`) 검증 통과
- 상태 창과 Windows 기본 브라우저 실행 확인
- Touch/Pen 연결 상태 및 웹 시각화 정상 확인
- 브라우저 탭을 연 상태에서도 종료 버튼으로 즉시 정상 종료 확인

빌드의 49개 경고는 모두 기존 Wacom vendor wrapper의 nullable annotation 및 analyzer
경고다. 프로젝트 자체에서 발생했던 중복 DPI manifest 경고는 제거했다.
