# macOS 터치·펜 동시 입력 및 성능 테스트

작성일: 2026-08-15  
대상 장치: Cintiq Pro 24 Touch  
실행 도구: `run-concurrent.sh`

이 문서는 macOS 터치·펜 동시 입력 조사 결과다.

## 1. 정상 종료된 25초 테스트

두 probe를 별도 프로세스로 동시에 실행하고 1초마다 CPU와 RSS를 기록했다. touch callback과
AppKit monitor는 기존 고정 크기 queue에 snapshot을 넣고, 별도 consumer가 원시 로그를 썼다.

### 종료 결과

```text
touchStatus=0
penStatus=0

touch: frames=2279 contacts=5958 queueDropped=0 truncatedFrames=0
pen:   local=247 global=224 point=455 proximity=16
       tabletSubtype=463 queueDropped=0
```

touch와 pen 모두 local/global 경로를 포함해 정상 종료했으며 queue drop은 없었다. 두 손가락을
움이는 동안 펜촉으로 그린 구간에는 touch와 겹친 pen point 455개, 양의 pressure point 109개가
기록됐고 최대 pressure는 `0.6902`였다.

### touch callback 간격

입력이 활성화된 구간에서 100ms 이하의 연속 프레임 간격을 계산했다.

| 통계 | 간격 |
| --- | --- |
| 중앙값 | 5ms |
| p95 | 8ms |
| p99 | 10ms |
| 최대 | 30ms |

관찰된 중앙 처리율은 약 200 frame/s다. 현재 값은 console 원시 로그 기록 비용까지 포함한다.

### 프로세스 자원

첫 cold-start 표본을 제외한 24개 1초 표본:

| 프로세스 | 평균 CPU | 최대 CPU | 평균 RSS | RSS 범위 |
| --- | ---: | ---: | ---: | ---: |
| touch probe | 1.70% | 5.00% | 32.5MiB | 32.4–32.5MiB |
| pen probe | 2.91% | 9.90% | 54.2MiB | 53.8–54.4MiB |

25초 관찰 동안 지속적인 RSS 증가 양상은 없었다.

## 2. 펜 접근 중 touch 동작

### 세 손가락 유지 구간

```text
t=1.917  id=0 down, confidence=true
t=1.927  id=1 down, confidence=true
t=3.482  id=2 down, confidence=true
t=5.735  pen proximity enter
t=5.810  id=0,1,2 모두 hold, confidence=false
t=7.382  pen proximity exit
t=7.715  pen proximity enter
t=8.386  pen proximity exit
t=8.495  touch FrameNumber 1265 -> 1, ID 0,1,2 유지
t=8.515  pen proximity enter
t=8.712  pen proximity exit
t=10.786~10.815 물리적 release, ID 2/1/0 순서로 up
```

첫 pen enter 후 약 75ms 뒤 세 접점의 confidence가 동시에 `false`가 됐다. 접점은 제거되지
않았고 `hold` 상태와 ID `0,1,2`가 유지됐다. pen이 proximity 밖으로 나간 뒤에도 손가락을
떼기 전까지 confidence가 다시 `true`가 되는 것은 관찰되지 않았다.

### 두 손가락과 실제 펜촉 동시 사용 구간

```text
t=15.002~15.007  touch ID 0,1 down, confidence=true
t=16.182         pen proximity enter
t=16.261         touch ID 0,1 hold, confidence=false
t=16.954~17.580  pen tip down/drag/up; touch와 동시 수집
t=17.683         pen proximity exit
t=17.947         touch ID 0,1 up
```

두 번째 구간도 pen enter 약 79ms 뒤 confidence가 `false`로 바뀌었다. pen point와 touch frame은
동시에 계속 수집됐다.

## 3. 구현에 반영할 결론

1. `Confidence=false` 접점을 앱에서 제거하지 않고 그대로 전송한다.
2. 이번 재현에서는 펜 접근으로 touch가 사라졌다가 다시 나타나는 현상은 없었다. confidence만
   바뀌었으며 ID는 유지됐다.
3. `FrameNumber`는 접촉이 유지되는 중에도 `1265 -> 1`로 재시작했다. WebSocket의 전역 순번이나
   중복 판정 키로 사용할 수 없고, 브리지 자체의 단조 증가 `sequence`가 필요하다.
4. pen proximity는 native event와 mouse subtype 쌍으로 중복 관찰되므로 서버 경계에서 dedupe한다.
5. 두 입력 callback/monitor는 WebSocket 송신과 분리된 고정 크기 queue에 계속 넣어야 한다.
6. 이번 부하에서 drop과 지속적인 메모리 증가는 없었다. 서버 연결 이후 느린 WebSocket client와
   disconnect/reconnect 부하는 별도로 다시 검증한다.

## 4. 추가 장시간 표본

첫 55초 실행에서 최대 5개 접점과 `confidence=false` 접점을 확인했다. 실행 세션이 로그를 읽는
중에 input 로그가 복제되어 종료 summary가 없는 보존본이므로, pass/fail 수치에는 사용하지 않고
최대 접점과 필드 관찰에만 사용한다.

## 5. 결과 파일

- `run-concurrent.sh`: 동시 실행 및 1초 자원 샘플링
- `raw/concurrent-touch.log`: 정상 종료 touch 로그
- `raw/concurrent-pen.log`: 정상 종료 pen 로그
- `raw/concurrent-performance.log`: 정상 종료 자원 로그
- `raw/concurrent-interrupted-touch.log`: 최대 5접점 장시간 표본
- `raw/concurrent-interrupted-pen.log`: 장시간 pen 표본
- `raw/concurrent-interrupted-performance.log`: 장시간 자원 표본
