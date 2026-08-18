# Wacom Input Test 1.0.0 — Windows x64

릴리스 검증일: 2026-08-18

## 배포 파일

- 실행 파일: `dist/windows/WacomInputTest.exe`
- 체크섬: `dist/windows/WacomInputTest.exe.sha256`
- 크기: 63,685,985 bytes (약 60.74 MiB)
- SHA-256: `5527adcb8f10a796d0c2870e6df44b9b1af3b9763e6f69fbefd74c64543d8744`
- 대상: Windows x64
- 배포 형식: self-contained, compressed single-file, Windows GUI subsystem

저장소 루트의 기존 `WacomInputTest.exe`는 포팅 전 기준 파일이며 릴리스 파일이 아니다.

## 실행 요구 사항

- Wacom Cintiq와 호환되는 Windows x64 환경
- 설치된 최신 Wacom 드라이버
- localhost `127.0.0.1:8765` 포트를 사용할 수 있는 상태

.NET 런타임은 실행 파일에 포함되어 있다. `WacomMT.dll`과 `Wintab32.dll`은 제품에
복사하지 않고 설치된 Wacom 드라이버에서 로드한다.

## 사용 방법

1. `WacomInputTest.exe`를 실행한다.
2. 상태 창에서 Touch와 Pen 연결 표시가 초록색인지 확인한다.
3. 자동으로 열린 기본 브라우저에서 입력을 확인한다.
4. 브라우저를 다시 열려면 상태 창의 브라우저 열기 버튼을 사용한다.
5. 종료 버튼 또는 창 닫기를 사용해 브리지와 로컬 서버를 함께 종료한다.

브라우저 탭만 닫아도 앱은 계속 실행된다. 앱 종료는 상태 창에서 수행한다.

## 검증 결과

- 자동 네이티브 계약 테스트 7/7 통과
- protocol 1 공통 웹 UI 호환성 테스트 통과
- x64 PE 및 GUI subsystem 검사 통과
- 단일 EXE와 SHA-256 파일 생성 검사 통과
- 상태 창, 기본 브라우저 실행 및 브라우저 탭을 연 상태의 정상 종료 확인
- 단일·다중 터치 입력 확인
- 펜 호버, 압력, 기울기, 버튼, 지우개 및 proximity 확인
- 실사용 범위인 터치 2개와 펜의 동시 입력 확인

## 입력 표시 참고 사항

빠른 연속 탭에서 Wacom 드라이버가 같은 Finger ID를 재사용할 수 있다. 각 DOWN/UP
프레임은 별도로 처리되지만 웹 UI는 같은 ID의 마커를 갱신하고 UP 상태를 250ms 유지하므로
하나의 연속된 마커처럼 보일 수 있다. 화면의 터치 수는 누적 탭 수가 아니라 현재 동시에
활성화된 접점 수다.

빌드 중 표시되는 nullable/analyzer 경고는 공식 Wacom C# wrapper 소스에서 발생한다.
vendor 사본은 릴리스 과정에서 수정하지 않았다.

## 빌드 재현

필요 도구:

- .NET 10 SDK
- Node.js

저장소 루트의 Windows PowerShell에서 실행한다.

```powershell
.\native-bridge\build-windows.ps1
```

스크립트는 자동 회귀 테스트를 통과한 경우에만 `dist/windows` 산출물을 갱신한다.
공개 배포 시에는 조직의 Authenticode 인증서로 최종 EXE에 코드 서명하는 절차를 별도로
추가해야 한다. 현재 빌드 스크립트는 코드 서명을 수행하지 않는다.
