# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 개요

Sky Duel은 Godot 4.7(GDScript)로 만든 2D 실시간 공중전 게임입니다. 같은 방에 들어온 플레이어끼리 Supabase Realtime(Broadcast·Presence)으로 상태를 주고받습니다. 서버 코드와 DB 테이블은 없고 Realtime 채널만 씁니다. UI 문구와 주석은 한국어로 씁니다.

- Supabase 프로젝트는 NINE STORE 쇼핑몰과 같은 `nine-store`(`dyfieegfgskszpyldhzs`)를 빌려 씁니다. URL과 publishable 키는 `main.gd` 맨 위 상수에 있습니다. 채널 이름은 `skyduel-<방 이름>`입니다.
- 무료 요금제의 Realtime 메시지 한도가 있으니 전송 빈도(`SEND_HZ`)나 이벤트 수를 늘릴 때 주의합니다.

## 실행과 검증

Godot은 설치 프로그램 없이 `%USERPROFILE%\Apps\Godot`에 풀어 둔 실행 파일을 씁니다. 빌드, 린트, 단위 테스트는 없습니다.

```bash
# 게임 실행 (바탕화면 "Sky Duel" 바로가기와 같음)
"$USERPROFILE/Apps/Godot/Godot_v4.7.2-stable_win64.exe" --path .

# 편집기로 열기
"$USERPROFILE/Apps/Godot/Godot_v4.7.2-stable_win64.exe" --editor --path .
```

로그를 보려면 `Godot_v4.7.2-stable_win64_console.exe`를 씁니다. `--` 뒤의 사용자 인자로 자동 검증을 합니다(`main.gd`의 `_parse_args()`).

| 인자 | 효과 |
| --- | --- |
| `--bot --name=X --room=Y` | 메뉴를 건너뛰고 바로 접속해 스스로 조종합니다. 접속·격추 로그를 stdout에 찍습니다. |
| `--quit-after=초` | 시간이 지나면 `RESULT {...}` 통계 JSON을 찍고 종료합니다(봇 기본 20초). |
| `--hp=N` | 봇의 체력을 바꿉니다. 격추 흐름을 빨리 확인할 때 씁니다(`--hp=1`). |
| `--ai=N --level=0~2` | 봇이 방장일 때 띄울 AI 수와 난이도입니다(기본 3대, 보통). 봇은 메뉴 설정 파일을 쓰지 않습니다. |
| `--screenshot=경로` | 종료 직전 게임 화면을 PNG로 저장합니다. 창 모드에서만 의미가 있습니다. |

검증할 때는 같은 `--room`으로 `--headless` 봇 두 개를 동시에 띄워 `RESULT`의 `states`, `hits_given`/`hits_taken`, `kills`, `ai_owned`/`ai_seen`을 비교합니다. 혼자 들어간 봇은 `ai_owned: 3`이 나와야 합니다. 화면 확인은 OS 화면 캡처 대신 `--screenshot`을 씁니다. OS 캡처는 다른 창이 찍힐 수 있습니다.

## 웹 빌드와 배포 (Vercel)

웹 버전은 저장소에 커밋한 `web/` 폴더(Godot 웹 내보내기 결과)를 Vercel이 그대로 정적 파일로 서비스합니다. Vercel 빌드 환경에는 Godot가 없으므로 **코드를 바꾸면 로컬에서 다시 내보내고 `web/`까지 함께 커밋**해야 배포에 반영됩니다.

```bash
# 1) 웹으로 내보내기 (export_presets.cfg의 "Web" 프리셋 → web/index.html)
"$USERPROFILE/Apps/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . --export-release "Web" web/index.html

# 2) 로컬 확인 → http://localhost:8060
powershell -ExecutionPolicy Bypass -File tools/serve-web.ps1
```

- 내보내기 템플릿은 `%APPDATA%\Godot\export_templates\4.7.2.stable\`에 웹용(`web_nothreads_*.zip`)만 풀어 두었습니다. Godot 버전을 올리면 템플릿도 같은 버전으로 다시 받아야 합니다.
- 단일 스레드 빌드(`variant/thread_support=false`)라서 COOP/COEP 헤더 없이 어느 정적 호스팅에서도 열립니다.
- `vercel.json`이 빌드·설치 단계를 끄고 `web/`을 출력 폴더로 지정합니다. GitHub `main`에 푸시하면 Vercel이 자동 배포합니다.
- 웹에서는 시스템 글꼴을 쓸 수 없어 `fonts/NanumGothic-Regular.ttf`(OFL, 라이선스는 `fonts/OFL.txt`)를 포함합니다. 지우면 한글이 깨집니다.
- 터치 조작은 없어서 휴대폰에서는 플레이할 수 없습니다.

## 구조

- `main.tscn`: `Node2D` 하나에 `main.gd`만 붙어 있습니다. 메뉴 UI와 게임 화면을 모두 코드로 만들고, 게임 화면은 `_draw()`로 그립니다.
- `realtime_client.gd`: Godot용 Supabase SDK가 없어서 `WebSocketPeer`로 Phoenix 채널 프로토콜(`vsn=1.0.0`)을 직접 구현했습니다. 참가(`phx_join`), 25초 heartbeat, `broadcast` 송수신, presence `track`/`presence_state`/`presence_diff`만 다룹니다. 다시 track하면 같은 키가 joins와 leaves에 함께 오므로 joins에 없는 키만 퇴장으로 처리합니다.
- 스크립트끼리는 `class_name` 대신 `preload`로 참조합니다(`const RealtimeClient = preload(...)`). 편집기로 한 번도 import하지 않은 상태에서 헤드리스로 바로 실행해도 깨지지 않게 하려는 것입니다.
- 한글 글꼴은 포함한 나눔고딕을 메뉴 Theme과 `draw_string`에 함께 쓰고, 불러오지 못하면 `SystemFont`(맑은 고딕)로 대신합니다.

### 네트워크 권한 모델

권한 서버가 없으므로 상태마다 주인이 정해져 있습니다.

- 각 클라이언트는 자기 비행기와 자기 총알만 직접 움직입니다. 남의 비행기는 `state`를 받아 보간하고 다음 state까지 마지막 속도로 예측합니다(`_update_peers`).
- 총알은 `shot` 이벤트(시작 위치·각도)로 알리고, 받는 쪽이 같은 궤적을 직접 시뮬레이션합니다.
- 피격 판정은 맞은 쪽이 합니다. 맞은 쪽이 `hit`를 보내고, 격추면 쏜 쪽이 그 메시지를 받고 자기 점수를 올립니다. Broadcast는 `self: false`라 자기가 보낸 이벤트는 돌아오지 않습니다. 그래서 자기가 판정한 피격의 처리는 로컬에서 따로 합니다.

| 이벤트 | 보내는 쪽 | 내용 |
| --- | --- | --- |
| `state` | 각 플레이어, `SEND_HZ`(10Hz) | 위치, 각도, 속도, 체력, 생존, 점수 |
| `shot` | 총을 쏜 쪽(플레이어 또는 AI 주인) | 총알 id, 시작 위치, 각도 |
| `hit` | 맞은 쪽(AI는 그 주인) | 피해자, 쏜 쪽, 총알 id, 남은 체력, 격추 여부 |
| `ai` | 방장, 10Hz | 방장이 가진 AI 전체 상태 목록 하나 |

### AI 적기

- presence 키(플레이어 id)를 정렬했을 때 가장 작은 사람이 방장입니다. 방장만 `ai_planes`에 AI를 두고 움직이며, 방장이 메뉴에서 고른 수(`ai_count`, 0~`AI_MAX_COUNT`)만큼 띄웁니다(`_manage_ai`). 다른 사람의 메뉴 설정은 그 사람이 방장이 될 때만 쓰입니다.
- 난이도는 `AI_LEVELS`(쉬움·보통·어려움)의 선회 속도, 최고 속도, 발사 간격, 조준 흔들림, 발사 각도로 정해집니다. 방장은 `ai` 이벤트에 `level`을 실어 보내고, 다른 사람은 그것을 정보 줄에 표시만 합니다.
- 메뉴 입력값(닉네임, 방, AI 수, 난이도)은 출격할 때 `user://settings.cfg`에 저장하고 다음 실행 때 불러옵니다.
- 방장의 AI는 `ai_planes`에, 다른 사람이 받은 AI는 `peers`에 `ai: true`와 `owner`를 붙여 들어갑니다. 그래서 그리기, 점수판, 이름·색 조회(`_name_of`, `_color_of`)는 `peers`와 `ai_planes`를 모두 봐야 합니다.
- AI의 피격 판정도 방장이 합니다. AI끼리는 서로 맞지 않습니다. 방장이 나가면 그 `owner`의 AI를 지우고, 다음 방장이 새로 띄웁니다.

## GDScript 주의점

- `Dictionary` 값처럼 Variant를 돌려주는 식에 `:=`를 쓰면 타입 추론 오류가 납니다. `var x: Vector2 = d["pos"]`처럼 타입을 적거나 `float()`, `str()`로 감쌉니다.
- 비행기, 총알, 효과는 모두 Dictionary로 다룹니다. 키를 바꿀 때는 보내는 쪽(`_send_state`, `_send_ai`)과 받는 쪽(`_upsert_peer`)을 함께 바꿉니다.
