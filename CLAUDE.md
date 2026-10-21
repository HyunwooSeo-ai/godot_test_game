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

서비스 주소는 https://godottestgame.vercel.app 이고, Vercel 프로젝트는 팀 `shw4`의 `godot_test_game`입니다(GitHub `HyunwooSeo-ai/godot_test_game`의 `main`과 연결).

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
- 터치 조작은 없어서 휴대폰에서는 플레이할 수 없습니다. 그래서 `web_shell.html`이 터치 전용 기기를 감지하면 엔진을 받기 전에 "PC에서 플레이해 주세요" 안내(`#mobile-notice`, 링크 복사·그래도 열어 보기)를 띄우고, 엔진은 `startEngine()`을 부를 때만 받습니다.
- 초대 링크는 `?room=방이름`입니다. 웹에서 `JavaScriptBridge`로 읽어 메뉴의 방 이름을 채우고(`_apply_invite_from_url`), 메뉴 버튼·L 키가 `DisplayServer.clipboard_set`으로 복사합니다. PC 버전은 `SITE_URL`로 링크를 만듭니다. canonical은 `?room` 없는 주소라 SEO에는 영향이 없습니다.
- 효과음(발사·피격·폭발·출격)은 `main.gd`의 "효과음" 섹션이 코드로 합성하고, 거리만큼 작게 냅니다. M 키로 끄고 켜며 `user://settings.cfg`의 `muted`에 저장합니다. 데모(홍보 영상)·봇 모드에서는 소리를 내지 않습니다.
- 첫 접속 다운로드는 Vercel 브로틀리 압축 덕분에 약 10.5MB(wasm 9.3MB)입니다. 문구를 바꿀 때 참고합니다.
- `web/.gdignore`는 Godot가 `web/` 안의 파일을 리소스로 가져오지 않게 합니다. 지우면 `.import` 파일이 생기고 pck에도 섞입니다.
- 푸시 후 배포가 반영됐는지는 `curl -s https://godottestgame.vercel.app/<파일> | grep <바뀐 내용>`을 반복해 확인합니다(보통 30초 안).
- `og-image.png`는 `--screenshot`으로 찍은 게임 화면을 1200×630으로 잘라 제목을 얹은 것입니다. 그래픽을 크게 바꾸면 다시 만듭니다.

### SEO · AEO · GEO

- `web_shell.html`이 웹 내보내기의 HTML 셸입니다(`export_presets.cfg`의 `html/custom_html_shell`). Godot 기본 셸을 바탕으로 메타 태그, Open Graph/X 카드, canonical, JSON-LD(`WebSite`, `VideoGame`+`WebApplication`, `FAQPage`)와 "게임 정보" 버튼으로 여는 본문(`<main id="about">`)을 더했습니다. `web/index.html`은 내보낼 때마다 덮어써지므로 **고칠 때는 `web_shell.html`을 고칩니다.**
- FAQ는 JSON-LD와 본문 두 곳에 같은 내용으로 있습니다. 게임 규칙(체력, 속도, AI 설정 등)을 바꾸면 두 곳과 `web/llms.txt`를 함께 고칩니다.
- 엔진이 시작하면서 문서 제목을 프로젝트 이름으로 바꾸기 때문에, 셸의 스크립트가 `MutationObserver`로 검색용 `<title>`을 되돌립니다. `project.godot`의 `config/name`은 바꾸지 않습니다(`user://` 저장 위치가 바뀝니다).
- `web/`에 직접 둔 정적 파일: `robots.txt`(AI 크롤러 포함 전체 허용), `sitemap.xml`, `llms.txt`, `og-image.png`(1200×630). 내보내기는 `index.*`만 덮어쓰므로 지워지지 않습니다. 날짜가 바뀌는 큰 변경이면 `sitemap.xml`의 `lastmod`를 갱신합니다.
- `web/googlea4d164898e2b8dbd.html`은 Google Search Console 소유권 확인 파일입니다(URL 접두어 속성 `https://godottestgame.vercel.app/`, 사이트맵 제출 완료). 지우면 소유권 확인이 풀립니다. 네이버 서치어드바이저 확인은 `web_shell.html`의 `naver-site-verification` 메타 태그입니다.

## 홍보 영상 (promo/)

```bash
# 1) 렌더링 → promo/output/sky_duel_promo.avi (1080x1920, 30fps, 28초, 약 40초 걸림)
powershell -ExecutionPolicy Bypass -File tools/render-promo.ps1
# 2) MP4 변환(Windows 내장 Media Foundation, H.264+AAC) → promo/output/sky_duel_promo.mp4
powershell -ExecutionPolicy Bypass -File tools/avi-to-mp4.ps1 -Src promo/output/sky_duel_promo.avi
```

- `promo/promo.gd`가 `main.tscn`을 SubViewport에 띄우고 `start_demo()`(네트워크 없는 오프라인 데모, 내 비행기는 봇)를 부른 뒤, 그 위에 자막·칩·CTA를 그리고 음악·효과음을 코드로 합성합니다. 장면 시간표는 `CAPTIONS`, `IMPACTS` 상수입니다. 쇼츠 규칙상 30초를 넘기지 않습니다.
- Movie Maker는 창이 아니라 프로젝트 기본 화면 크기로 녹화하므로, 렌더 스크립트가 잠깐 `override.cfg`로 1080x1920 + stretch `viewport`를 지정하고 끝나면 지웁니다(창이 화면보다 커도 전체 해상도로 그려짐). `override.cfg`가 남아 있으면 게임이 세로 화면으로 뜨니 지웁니다.
- 스크립트 오류가 나면 빈 장면이 끝없이 녹화되므로 `--quit-after 900`으로 막아 두었습니다. 렌더 전에 `--headless --quit-after 10 res://promo/promo.tscn`으로 오류부터 확인합니다.
- `promo/`는 웹 내보내기에서 제외(`exclude_filter`)하고, `promo/output/`은 용량 때문에 git에 올리지 않습니다.
- 검수: `tools/avi-frames.ps1 -Avi <avi> -OutDir <폴더> -Seconds @(1.0, 5.0)`로 지정 시점의 JPEG 프레임과 프레임 수·길이를 뽑습니다. Godot AVI의 영상 청크 이름은 `00db`입니다(`00dc` 아님). `-Seconds`에 배열을 넘기려면 `powershell -File`이 아니라 `&`로 실행합니다.

## 구조

- `main.tscn`: `Node2D` 하나에 `main.gd`만 붙어 있습니다. 메뉴 UI와 게임 화면을 모두 코드로 만들고, 게임 화면은 `_draw()`로 그립니다.
- `realtime_client.gd`: Godot용 Supabase SDK가 없어서 `WebSocketPeer`로 Phoenix 채널 프로토콜(`vsn=1.0.0`)을 직접 구현했습니다. 참가(`phx_join`), 25초 heartbeat, `broadcast` 송수신, presence `track`/`presence_state`/`presence_diff`만 다룹니다. 다시 track하면 같은 키가 joins와 leaves에 함께 오므로 joins에 없는 키만 퇴장으로 처리합니다.
- 스크립트끼리는 `class_name` 대신 `preload`로 참조합니다(`const RealtimeClient = preload(...)`). 편집기로 한 번도 import하지 않은 상태에서 헤드리스로 바로 실행해도 깨지지 않게 하려는 것입니다.
- 화면은 위에서 내려다보는 2D지만 `main.gd`의 "연출" 섹션이 입체감을 더합니다: 비행기 그림자(`SHADOW_OFFSET`), 아래·위 두 층 구름, 선회 기울기(`bank`)에 따른 날개 음영, 비행운, 연기·폭발 파티클. 이 값들은 네트워크로 보내지 않고 각자 계산합니다(남의 기울기는 각도 변화로 추정). 지형은 고정 시드라 모두에게 같게 보입니다.
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
- `Array` 안의 `Vector2`/`Vector3`는 값 타입이라 `for s in arr: s.y += 1`은 원본을 바꾸지 않습니다. 인덱스로 꺼내 고친 뒤 다시 넣습니다.
- 다른 스크립트(`main.gd`)의 멤버를 쓰는 변수는 `var game: Node2D`처럼 엔진 타입으로 적으면 파싱 오류가 납니다. 타입 없이 `var game`으로 둡니다(`promo.gd` 참고).

## 환경 메모

- Node.js와 Python은 없습니다. Git은 `C:\Program Files\Git\cmd\git.exe`이고, push는 비대화형 셸에서도 인증 없이 됩니다.
- PowerShell 5.1에서 `git commit -m`의 메시지에 큰따옴표(`"`)가 있으면 인자가 깨집니다. 메시지를 파일로 써서 `git commit -F 파일`로 커밋합니다.
- 한글이 들어간 `.ps1` 스크립트는 UTF-8 **BOM**으로 저장해야 PowerShell 5.1이 제대로 읽습니다.
- 봇 여러 개를 동시에 띄우면 가끔 일부가 `joined: false`로 끝납니다(재현 안 되는 일시적 실패). 코드를 의심하기 전에 한 번 더 돌려 봅니다.
- 내장 브라우저 창이 가려져 있으면 게임 프레임이 느려져, 키 입력과 속도를 자동화로 확인할 수 없습니다. 조작감은 사람이 직접 확인합니다.
- Claude in Chrome은 `searchadvisor.naver.com`을 안전 제한으로 열지 못합니다(네이버 작업은 사용자가 직접). Google 검증 도구(validator.schema.org 등)는 CAPTCHA를 띄울 수 있습니다.
- 새 스크립트를 추가한 직후 첫 `--export-release`는 클래스 스캔 때문에 종료 코드 -1을 낼 수 있습니다. 한 번 더 실행해 0이 나오면 정상입니다.
- 이 PC에는 HEVC(H.265) 코덱이 없어 Media Foundation이 HEVC 영상을 재생하거나 변환하지 못합니다. 휴대폰·카카오톡 영상은 대개 HEVC입니다. `avi-to-mp4.ps1`이 만드는 H.264는 문제없습니다.
