extends Node2D
## SKY DUEL: Supabase Realtime 실시간 공중전.
## 각 클라이언트는 자기 비행기와 자기 총알만 직접 움직이고, 피격 판정은 맞은 쪽(피해자)이 내립니다.
##   state 이벤트: 내 위치·체력·점수 (초당 SEND_HZ회)
##   shot  이벤트: 총알 발사 (받는 쪽이 같은 궤적을 시뮬레이션)
##   hit   이벤트: 피격 알림 (격추면 쏜 사람이 자기 점수를 올림)

const RealtimeClient = preload("res://realtime_client.gd")

const SUPABASE_URL := "https://yvnwcqndxvztidknkult.supabase.co"
const SUPABASE_KEY := "sb_publishable_vJF69wkepVHSlNL-RaR0vA_CfxxDE9q"
const CHANNEL_PREFIX := "skyduel-"
const SITE_URL := "https://godottestgame.vercel.app/"  # PC 버전에서 초대 링크를 만들 때 씁니다
const ARENA := Vector2(1280, 720)
const TURN_SPEED := 2.5
const MIN_SPEED := 100.0
const MAX_SPEED := 250.0
const START_SPEED := 160.0
const ACCEL := 150.0
const BULLET_SPEED := 480.0
const BULLET_LIFE := 1.4
const FIRE_COOLDOWN := 0.25
const MAX_HP := 3
const HIT_RADIUS := 25.0       # 기체 반경보다 조금 넉넉하게 잡아 스치는 총알도 맞게 합니다
const RESPAWN_SEC := 2.0
const SHIELD_SEC := 3.0
const WIN_SCORE := 5           # 이만큼 먼저 격추하면 그 판 승리
const ROUND_BREAK := 5.0       # 승리 발표 후 새 판까지
const ROUND_COOLDOWN := 2.0    # 새 판 직후 늦게 도착한 옛 점수로 다시 끝나지 않게 기다리는 시간
const SEND_HZ := 10.0
const PEER_TIMEOUT := 6.0
# 받은 메시지의 상한. 서버가 검사하지 않으므로 클라이언트마다 직접 막습니다.
const MAX_PEERS := 24              # 사람 + 받은 AI
const MAX_BULLETS := 200
const MAX_BULLETS_PER_OWNER := 10  # 사람은 연사 간격상 최대 6발 정도가 동시에 날아갑니다
const MAX_ID_LEN := 40
const SHOT_MEMORY := 3.0           # 내 총알 bid를 기억하는 시간(늦게 도착한 hit 대조용)
const AI_MAX_COUNT := 8
const AI_RESPAWN_SEC := 4.0
const AI_FIRE_RANGE := 430.0
# 난이도별 AI 성능. turn: 선회 속도, speed: 최고 속도, cooldown: 발사 간격(초),
# wobble: 조준 흔들림(라디안), cone: 이 각도 안에 들어오면 발사
const AI_LEVELS := [
	{"name": "쉬움", "turn": 1.3, "speed": 170.0, "cooldown": 1.5, "wobble": 0.4, "cone": 0.15},
	{"name": "보통", "turn": 1.7, "speed": 200.0, "cooldown": 1.0, "wobble": 0.25, "cone": 0.2},
	{"name": "어려움", "turn": 2.2, "speed": 235.0, "cooldown": 0.6, "wobble": 0.12, "cone": 0.25},
]
const SETTINGS_PATH := "user://settings.cfg"
const AI_NAMES := ["바이퍼", "매버릭", "아이스맨", "피닉스", "행맨", "루스터", "코요테", "페이백"]

const PLANE_SHAPE := [
	Vector2(22, 0), Vector2(8, -3), Vector2(2, -17), Vector2(-5, -17), Vector2(-4, -3),
	Vector2(-13, -3), Vector2(-17, -9), Vector2(-21, -9), Vector2(-18, 0), Vector2(-21, 9),
	Vector2(-17, 9), Vector2(-13, 3), Vector2(-4, 3), Vector2(-5, 17), Vector2(2, 17), Vector2(8, 3),
]

enum Mode { MENU, CONNECTING, PLAYING }

var mode := Mode.MENU
var rt: RealtimeClient
var room := ""
var room_notice := ""        # 입력한 방 이름이 바뀌었을 때 입장 후 피드에 알릴 문구

# 내 비행기
var my_id := ""
var my_name := ""
var my_color := Color.WHITE
var pos := Vector2.ZERO
var angle := 0.0
var speed := 200.0
var hp := MAX_HP
var alive := false
var score := 0
var deaths := 0
var respawn_left := 0.0
var shield := 0.0
var fire_cd := 0.0
var send_left := 0.0
var bullet_seq := 0
var bank := 0.0              # 선회할 때 기울어진 정도(-1~1). 그리기에만 씁니다.
var turn_rate := 0.0         # 지금 선회 속도(rad/s). state에 실어 보내 받는 쪽이 곡선으로 예측하게 합니다.

var bullets: Array = []      # { bid, owner, pos, vel, life }
var own_shots: Dictionary = {}  # 나와 내 AI가 쏜 bid -> 쏜 시각. hit가 오면 지워서 한 발이 한 번만 점수가 되게 합니다.
var seen_hits: Dictionary = {}  # 이미 처리한 hit의 bid -> 받은 시각
var id_regex := RegEx.create_from_string("^[0-9a-z-]+$")
var peers: Dictionary = {}   # id -> { name, color, pos, target, angle, target_angle, speed, hp, alive, score, last_seen }
var ai_planes: Dictionary = {}  # 내가 방장일 때 직접 움직이는 AI. id -> { name, color, pos, angle, speed, hp, alive, shield, fire_cd, respawn_left, score, wobble }
var ai_seq := 0
var ai_announced := false
var ai_count := 3            # 메뉴에서 정한 AI 수. 여럿이 할 때는 방장의 설정을 따릅니다.
var ai_level := 1            # AI_LEVELS 인덱스
var remote_ai_level := -1    # 방장이 다른 사람일 때 받은 난이도(점수판 표시용)
var effects: Array = []      # { pos, color, t, dur, size }
var feed: Array = []         # { text, t }

# 입체감 연출용 (네트워크와 무관)
var glints: Array = []       # 바다 물결 반짝임 Vector3(x, y, 위상)
var islands: Array = []      # { pos, blobs: [Vector3(x, y, r)] }
var clouds: Array = []       # { pos, puffs: [Vector3(x, y, r)], high, speed }
var particles: Array = []    # { pos, vel, life, max, size, color, smoke }
var trails: Dictionary = {}  # 비행기 id -> [[왼쪽 날개 끝, 오른쪽 날개 끝], ...]
var trail_left := 0.0
var smoke_left := 0.0
var hud_box: StyleBoxFlat
var glint_layer: Node2D      # 물결 반짝임 층(매 프레임 다시 그림). 나머지 배경 층은 한 번만 그립니다.

# 효과음 (코드로 합성)
var sfx: Dictionary = {}     # 이름 -> AudioStreamWAV
var sfx_players: Array = []  # AudioStreamPlayer 풀
var sfx_next := 0
var sfx_seed := 777
var muted := false

var font: Font
var menu_root: Control
var name_edit: LineEdit
var room_edit: LineEdit
var join_button: Button
var status_label: Label
var ai_count_spin: SpinBox
var ai_level_option: OptionButton

# 헤드리스 자동 테스트용 봇 (godot --headless -- --bot --name=Bot1 --room=test --quit-after=20)
var bot_mode := false
var demo_mode := false       # 홍보 영상용 오프라인 데모(네트워크 없이 AI와 싸움)
var bot_hp := MAX_HP
var _args: Dictionary = {}
var quit_after := 0.0
var win_score := WIN_SCORE
var round_over_left := 0.0     # > 0이면 승리 발표 중(발사 금지)
var round_cooldown := 0.0
var round_winner := ""
var esc_armed_left := 0.0      # Esc를 한 번 누른 뒤 두 번째를 기다리는 시간
var elapsed := 0.0

# 휴대폰 터치 조작. 왼쪽 절반은 떠 있는 조이스틱(민 방향으로 선회, 멀리 밀수록 빠름), 오른쪽 절반은 누르는 동안 발사.
const JOY_RADIUS := 110.0
const JOY_HOME := Vector2(200, ARENA.y - 190)
const FIRE_HOME := Vector2(ARENA.x - 190, ARENA.y - 190)
const FIRE_RADIUS := 95.0
const TOUCH_BUTTONS := ["sound", "invite", "leave"]
var is_phone := false          # 안드로이드·iOS 브라우저. 글자와 메뉴를 키웁니다.
var touch_mode := false        # 터치 조작 화면을 보일지. 화면을 만지면 켜지고 키보드를 쓰면 꺼집니다.
var hud_k := 1.0               # HUD 글자 배율(휴대폰은 크게)
var joy_index := -1            # 조이스틱을 잡은 손가락 번호
var joy_origin := Vector2.ZERO
var joy_vec := Vector2.ZERO
var fire_touches: Dictionary = {}  # 발사 중인 손가락 번호 -> true
var joined_at := 0.0
var menu_layer: CanvasLayer
var menu_panel: PanelContainer
var help_label: Label
var stats := {"joined": false, "peers_seen": 0, "states": 0, "shots": 0, "hits_taken": 0, "kills": 0}


func _ready() -> void:
	randomize()
	is_phone = OS.has_feature("web_android") or OS.has_feature("web_ios")
	touch_mode = is_phone
	hud_k = 1.35 if is_phone else 1.0
	font = _make_font()
	_build_scenery()
	_build_layers()
	_build_sfx()
	_build_menu()
	_apply_invite_from_url()
	var args := _parse_args()
	_args = args
	if args.has("phone"):
		# PC에서 휴대폰 화면 배치를 확인할 때 씁니다(--phone --screenshot=...).
		is_phone = true
		touch_mode = true
		hud_k = 1.35
	if is_phone:
		_fit_menu_for_phone.call_deferred()
	quit_after = float(args.get("quit-after", "0"))
	if args.has("bot"):
		bot_mode = true
		if quit_after <= 0.0:
			quit_after = 20.0
		bot_hp = int(args.get("hp", str(MAX_HP)))
		win_score = maxi(1, int(args.get("win", str(WIN_SCORE))))
		ai_count = clampi(int(args.get("ai", "3")), 0, AI_MAX_COUNT)
		ai_level = clampi(int(args.get("level", "1")), 0, AI_LEVELS.size() - 1)
		_start(str(args.get("name", "Bot")), str(args.get("room", "test")))


func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		var s := str(arg).trim_prefix("--")
		var eq := s.find("=")
		if eq >= 0:
			out[s.substr(0, eq)] = s.substr(eq + 1)
		else:
			out[s] = "true"
	return out


func _make_font() -> Font:
	# 웹에서는 시스템 글꼴을 쓸 수 없어서 나눔고딕(OFL)을 게임에 포함합니다.
	var bundled := load("res://fonts/NanumGothic-Regular.ttf") as Font
	if bundled:
		return bundled
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Malgun Gothic", "맑은 고딕", "Noto Sans CJK KR", "Sans-Serif"])
	return f


# ---------------------------------------------------------------- 메뉴

func _box(bg: Color, radius: int, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.anti_aliasing = true
	return sb


func _style_theme(theme: Theme) -> void:
	# 반투명 유리 패널 + 주황색 강조 버튼
	var panel := _box(Color(0.03, 0.08, 0.15, 0.82), 18, Color(1, 1, 1, 0.12))
	panel.shadow_color = Color(0, 0, 0, 0.35)
	panel.shadow_size = 24
	theme.set_stylebox("panel", "PanelContainer", panel)

	var field := _box(Color(1, 1, 1, 0.07), 10, Color(1, 1, 1, 0.12))
	var field_focus := _box(Color(1, 1, 1, 0.1), 10, Color(1, 0.7, 0.35))
	for type in ["LineEdit", "OptionButton"]:
		theme.set_stylebox("normal", type, field)
		theme.set_stylebox("focus", type, field_focus)
	theme.set_stylebox("hover", "OptionButton", field_focus)
	theme.set_stylebox("pressed", "OptionButton", field_focus)
	theme.set_color("font_color", "OptionButton", Color.WHITE)
	theme.set_color("font_hover_color", "OptionButton", Color.WHITE)
	theme.set_color("font_pressed_color", "OptionButton", Color.WHITE)
	theme.set_color("font_focus_color", "OptionButton", Color.WHITE)

	var accent := Color(1.0, 0.56, 0.22)
	theme.set_stylebox("normal", "Button", _box(accent, 12, accent.lightened(0.3)))
	theme.set_stylebox("hover", "Button", _box(accent.lightened(0.15), 12, accent.lightened(0.4)))
	theme.set_stylebox("pressed", "Button", _box(accent.darkened(0.15), 12, accent))
	theme.set_stylebox("disabled", "Button", _box(Color(0.4, 0.4, 0.45, 0.6), 12, Color(1, 1, 1, 0.1)))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(key, "Button", Color(0.12, 0.06, 0.02))

func _build_menu() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu_layer = layer
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 20
	_style_theme(theme)
	hud_box = _box(Color(0.02, 0.06, 0.12, 0.55), 10, Color(1, 1, 1, 0.08))

	menu_root = CenterContainer.new()
	menu_root.theme = theme
	menu_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(menu_root)

	var panel := PanelContainer.new()
	menu_root.add_child(panel)
	menu_panel = panel
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.custom_minimum_size = Vector2(360, 0)
	margin.add_child(box)

	var title := Label.new()
	title.text = "SKY DUEL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1, 0.88, 0.6))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	title.add_theme_constant_override("shadow_offset_y", 3)
	box.add_child(title)
	box.add_child(_label("Supabase Realtime 실시간 공중전", 16, Color(0.7, 0.8, 1.0)))

	box.add_child(_label("닉네임", 16))
	name_edit = LineEdit.new()
	name_edit.max_length = 12
	name_edit.text = "Pilot%03d" % (randi() % 1000)
	box.add_child(name_edit)

	box.add_child(_label("방 이름 (같은 방끼리 대결)", 16))
	room_edit = LineEdit.new()
	room_edit.max_length = 20
	room_edit.text = "lobby"
	room_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	box.add_child(room_edit)

	var invite_button := Button.new()
	invite_button.text = "초대 링크 복사"
	invite_button.custom_minimum_size = Vector2(0, 36)
	invite_button.add_theme_font_size_override("font_size", 16)
	var flat := _box(Color(1, 1, 1, 0.07), 10, Color(1, 1, 1, 0.18))
	invite_button.add_theme_stylebox_override("normal", flat)
	invite_button.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.14), 10, Color(1, 0.7, 0.35)))
	invite_button.add_theme_stylebox_override("pressed", flat)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		invite_button.add_theme_color_override(key, Color(0.85, 0.92, 1.0))
	invite_button.pressed.connect(func() -> void:
		var url := _copy_invite(_clean_room(room_edit.text))
		status_label.text = "초대 링크를 복사했어요. 친구에게 보내 주세요!\n" + url)
	box.add_child(invite_button)

	# AI 적기 설정. 여럿이 할 때는 방장(접속자 id가 가장 작은 사람)의 설정만 쓰입니다.
	var ai_row := HBoxContainer.new()
	ai_row.add_theme_constant_override("separation", 10)
	box.add_child(ai_row)
	var count_label := _label("AI 적기", 16)
	ai_row.add_child(count_label)
	ai_count_spin = SpinBox.new()
	ai_count_spin.min_value = 0
	ai_count_spin.max_value = AI_MAX_COUNT
	ai_count_spin.step = 1
	ai_count_spin.suffix = "대"
	ai_count_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_row.add_child(ai_count_spin)
	ai_row.add_child(_label("난이도", 16))
	ai_level_option = OptionButton.new()
	for level in AI_LEVELS:
		ai_level_option.add_item(str(level["name"]))
	ai_level_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_row.add_child(ai_level_option)
	box.add_child(_label("여럿이 할 때는 방장 한 명의 AI 설정을 따릅니다", 14, Color(1.0, 0.6, 0.55)))

	join_button = Button.new()
	join_button.text = "출격"
	join_button.custom_minimum_size = Vector2(0, 44)
	join_button.pressed.connect(_on_join_pressed)
	box.add_child(join_button)

	status_label = _label("", 16, Color(1.0, 0.75, 0.4))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)
	help_label = _label("←→ / A D 회전   ↑↓ / W S 속도\nSpace 발사   L 초대 링크   M 소리   Esc 두 번: 나가기", 15, Color(0.75, 0.75, 0.8))
	box.add_child(help_label)
	_load_settings()


func _fit_menu_for_phone() -> void:
	# 휴대폰은 1280x720 화면이 절반 정도로 줄어 글자가 작아지므로, 화면 높이에 맞는 한 메뉴를 키웁니다.
	help_label.text = "왼쪽 화면을 끌어 조종(멀리 밀수록 빨라요)\n오른쪽 화면을 누르고 있으면 발사"
	await get_tree().process_frame
	var h := maxf(menu_panel.size.y, 1.0)
	var k := clampf((ARENA.y - 16.0) / h, 1.0, 1.4)
	menu_layer.scale = Vector2(k, k)
	menu_layer.offset = ARENA * (1.0 - k) / 2.0


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		name_edit.text = str(cfg.get_value("menu", "name", name_edit.text))
		room_edit.text = str(cfg.get_value("menu", "room", room_edit.text))
		ai_count = clampi(int(cfg.get_value("menu", "ai_count", ai_count)), 0, AI_MAX_COUNT)
		ai_level = clampi(int(cfg.get_value("menu", "ai_level", ai_level)), 0, AI_LEVELS.size() - 1)
		muted = bool(cfg.get_value("menu", "muted", false))
		AudioServer.set_bus_mute(0, muted)
	ai_count_spin.value = ai_count
	ai_level_option.select(ai_level)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("menu", "name", name_edit.text)
	cfg.set_value("menu", "room", room_edit.text)
	cfg.set_value("menu", "ai_count", ai_count)
	cfg.set_value("menu", "ai_level", ai_level)
	cfg.set_value("menu", "muted", muted)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- 초대 링크
# https://godottestgame.vercel.app/?room=방이름 으로 들어오면 방 이름을 채워 둡니다(출격은 사용자가 누름).

func _clean_room(text: String) -> String:
	# 한글(완성형·자모), 영문 소문자, 숫자, _ - 만 남깁니다.
	var regex := RegEx.create_from_string("[^a-z0-9가-힣ㄱ-ㅣ_-]")
	var r := regex.sub(text.strip_edges().to_lower(), "", true).left(20)
	return r if not r.is_empty() else "lobby"


func _channel_of(room_name: String) -> String:
	# 영문 방 이름은 그대로 써서 예전 링크와 맞추고, 한글이 섞이면 해시로 바꿔 채널 이름을 ASCII로 유지합니다.
	# "u."의 점은 _clean_room이 지우는 문자라 영문 방 이름과 겹치지 않습니다.
	if RegEx.create_from_string("^[a-z0-9_-]+$").search(room_name):
		return CHANNEL_PREFIX + room_name
	return CHANNEL_PREFIX + "u." + room_name.sha256_text().left(16)


func _invite_url(room_name: String) -> String:
	var base := SITE_URL
	if OS.has_feature("web"):
		base = str(JavaScriptBridge.eval("location.origin + location.pathname", true))
	return base + "?room=" + room_name.uri_encode()


func _copy_invite(room_name: String) -> String:
	var url := _invite_url(room_name)
	DisplayServer.clipboard_set(url)
	return url


func _apply_invite_from_url() -> void:
	if not OS.has_feature("web"):
		return
	var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('room') || ''", true))
	if q.strip_edges().is_empty():
		return
	room_edit.text = _clean_room(q)
	status_label.text = "친구가 초대한 방 '%s'이에요. 닉네임을 확인하고 출격하세요!" % room_edit.text


func _label(text: String, size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _on_join_pressed() -> void:
	if mode != Mode.MENU:
		return
	var nick := name_edit.text.strip_edges()
	if nick.is_empty():
		nick = "Pilot"
	ai_count = int(ai_count_spin.value)
	ai_level = maxi(0, ai_level_option.selected)
	_save_settings()
	var clean := _clean_room(room_edit.text)
	if clean != room_edit.text.strip_edges().to_lower():
		room_notice = "방 이름에는 한글·영문·숫자·_·-만 쓸 수 있어 '%s' 방으로 들어갔어요" % clean
	_start(nick, clean)


# ---------------------------------------------------------------- 접속

func _start(nick: String, room_name: String) -> void:
	my_id = "%08x%04x" % [randi(), randi() % 0x10000]
	my_name = nick
	room = room_name
	my_color = Color.from_hsv(randf(), 0.6, 1.0)
	score = 0
	deaths = 0
	mode = Mode.CONNECTING
	join_button.disabled = true
	status_label.text = "접속 중..."

	rt = RealtimeClient.new()
	add_child(rt)
	rt.joined.connect(_on_joined)
	rt.failed.connect(_on_failed)
	rt.broadcast_received.connect(_on_broadcast)
	rt.presence_joined.connect(_on_presence_joined)
	rt.presence_left.connect(_on_presence_left)
	rt.connect_room(SUPABASE_URL, SUPABASE_KEY, _channel_of(room), my_id)


func _on_joined() -> void:
	mode = Mode.PLAYING
	menu_root.visible = false
	stats["joined"] = true
	_log("joined room=%s id=%s" % [room, my_id])
	rt.track({"id": my_id, "name": my_name, "color": my_color.to_html(false)})
	_spawn()
	joined_at = elapsed
	_reset_touch()
	_set_page_playing(true)
	_add_feed("'%s' 방에 입장했습니다" % room)
	if room_notice != "":
		_add_feed(room_notice)
		room_notice = ""


func _on_failed(reason: String) -> void:
	_log("failed: " + reason)
	_back_to_menu(reason)


func _leave() -> void:
	if rt:
		rt.leave()
	_back_to_menu("")


func _back_to_menu(message: String) -> void:
	if rt:
		var old := rt
		rt = null
		# leave 메시지가 나갈 시간을 준 뒤 정리합니다.
		get_tree().create_timer(0.5).timeout.connect(old.queue_free)
	mode = Mode.MENU
	alive = false
	peers.clear()
	ai_planes.clear()
	ai_announced = false
	remote_ai_level = -1
	round_over_left = 0.0
	round_cooldown = 0.0
	esc_armed_left = 0.0
	bullets.clear()
	own_shots.clear()
	seen_hits.clear()
	feed.clear()
	trails.clear()
	_reset_touch()
	_set_page_playing(false)
	menu_root.visible = true
	join_button.disabled = false
	status_label.text = message


func _set_page_playing(on: bool) -> void:
	# 휴대폰에서는 게임 중에 셸의 "게임 정보" 버튼이 발사 영역을 가리지 않도록 숨깁니다(web_shell.html의 body.playing).
	if OS.has_feature("web"):
		JavaScriptBridge.eval("document.body.classList.toggle('playing', %s)" % ("true" if on else "false"), true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		touch_mode = false
		if event.keycode == KEY_ESCAPE and mode == Mode.PLAYING:
			_request_leave("Esc를 한 번 더 누르면 메뉴로 나가요")
		elif event.physical_keycode == KEY_M and mode == Mode.PLAYING:
			_toggle_mute()
		elif event.physical_keycode == KEY_L and mode == Mode.PLAYING:
			_copy_invite(room)
			_add_feed("초대 링크를 복사했어요. 친구에게 보내 주세요! (L)")


func _request_leave(hint: String) -> void:
	# 실수로 나가지 않도록 2초 안에 한 번 더 눌러야 나갑니다.
	if esc_armed_left > 0.0:
		_leave()
	else:
		esc_armed_left = 2.0
		_add_feed(hint)


# ---------------------------------------------------------------- 터치 조작

func _input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	touch_mode = true
	if mode != Mode.PLAYING:
		return  # 메뉴는 터치가 마우스로 바뀌어 버튼·입력칸에 그대로 전달됩니다.
	var p: Vector2 = event.position
	var idx: int = event.index
	if event is InputEventScreenTouch:
		if event.pressed:
			var button := _touch_button_at(p)
			if button != "":
				_press_touch_button(button)
			elif p.x < ARENA.x * 0.5:
				if joy_index == -1:
					joy_index = idx
					joy_origin = p
					joy_vec = Vector2.ZERO
			else:
				fire_touches[idx] = true
		else:
			if idx == joy_index:
				joy_index = -1
				joy_vec = Vector2.ZERO
			fire_touches.erase(idx)
	elif idx == joy_index:
		joy_vec = (p - joy_origin).limit_length(JOY_RADIUS)


func _reset_touch() -> void:
	joy_index = -1
	joy_vec = Vector2.ZERO
	fire_touches.clear()


func _touch_button_rect(i: int) -> Rect2:
	# 아래 가운데의 작은 버튼 3개(조이스틱·발사 영역 사이)
	var w := 132.0
	var gap := 14.0
	var x0 := ARENA.x / 2.0 - (w * 3.0 + gap * 2.0) / 2.0
	return Rect2(x0 + i * (w + gap), ARENA.y - 70.0, w, 54.0)


func _touch_button_at(p: Vector2) -> String:
	for i in TOUCH_BUTTONS.size():
		if _touch_button_rect(i).grow(6.0).has_point(p):
			return TOUCH_BUTTONS[i]
	return ""


func _press_touch_button(button: String) -> void:
	match button:
		"sound":
			_toggle_mute()
		"invite":
			_copy_invite(room)
			_add_feed("초대 링크를 복사했어요. 친구에게 보내 주세요!")
		"leave":
			_request_leave("나가기를 한 번 더 누르면 메뉴로 나가요")


func _touch_controls() -> Array:
	# [선회, 가속, 발사]. 조이스틱 방향으로 기수를 돌리고, 민 거리로 목표 속도를 정합니다.
	var turn := 0.0
	var thrust := 0.0
	var mag := joy_vec.length() / JOY_RADIUS
	if joy_index != -1 and mag > 0.2:
		var diff := wrapf(joy_vec.angle() - angle, -PI, PI)
		turn = clampf(diff * 3.0, -1.0, 1.0)
		var want := lerpf(MIN_SPEED, MAX_SPEED, clampf((mag - 0.2) / 0.8, 0.0, 1.0))
		thrust = clampf((want - speed) / 30.0, -1.0, 1.0)
	return [turn, thrust, not fire_touches.is_empty()]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and rt:
		rt.leave()


# ---------------------------------------------------------------- 매 프레임

func _process(delta: float) -> void:
	elapsed += delta
	if bot_mode and elapsed > 3.0:
		# 끊김 점검용: 시작 3초 뒤부터 가장 긴 프레임과 프레임 수를 셉니다.
		stats["frames"] = int(stats.get("frames", 0)) + 1
		stats["worst_frame_ms"] = maxf(float(stats.get("worst_frame_ms", 0.0)), snappedf(delta * 1000.0, 0.1))
	if quit_after > 0.0 and elapsed >= quit_after:
		quit_after = 0.0
		_finish_bot()
		return
	if mode == Mode.PLAYING:
		_update_me(delta)
		_update_bullets(delta)
		_update_peers(delta)
		_manage_ai()
		_update_ai(delta)
		_update_round(delta)
		esc_armed_left = maxf(0.0, esc_armed_left - delta)
		send_left -= delta
		if send_left <= 0.0:
			send_left = 1.0 / SEND_HZ
			_send_state()
			_send_ai()
			_prune_shot_memory()
		_update_trails(delta)
	_update_effects(delta)
	_update_scenery(delta)
	queue_redraw()


func _board() -> Array:
	# 점수판 항목: 나, 다른 플레이어(받은 AI 포함), 내가 방장일 때의 AI
	var board := [{"name": my_name, "score": score, "color": my_color, "me": true}]
	for peer in peers.values():
		board.append({"name": peer["name"], "score": peer["score"], "color": peer["color"], "me": false})
	for ai in ai_planes.values():
		board.append({"name": ai["name"], "score": ai["score"], "color": ai["color"], "me": false})
	board.sort_custom(func(l: Dictionary, r: Dictionary) -> bool: return int(l["score"]) > int(r["score"]))
	return board


func _update_round(delta: float) -> void:
	# 판 진행: 누군가 win_score에 닿으면 모두가 각자 같은 점수를 보고 승리를 발표하고,
	# ROUND_BREAK 뒤에 각자 자기 점수(방장은 AI 점수도)를 0으로 돌립니다. 서버 없이 같은 규칙으로 맞춥니다.
	if demo_mode:
		return
	if round_over_left > 0.0:
		round_over_left -= delta
		if round_over_left <= 0.0:
			score = 0
			deaths = 0
			for ai in ai_planes.values():
				ai["score"] = 0
			round_cooldown = ROUND_COOLDOWN
			stats["rounds"] = int(stats.get("rounds", 0)) + 1
			_add_feed("새 판 시작! %d대를 먼저 격추하세요" % win_score)
			_play_sfx("spawn", pos, -4.0)
			_send_state()
		return
	if round_cooldown > 0.0:
		round_cooldown -= delta
		return
	var top: Dictionary = _board()[0]
	if int(top["score"]) >= win_score:
		round_winner = str(top["name"])
		round_over_left = ROUND_BREAK
		_add_feed("%s 승리! (%d격추)" % [round_winner, int(top["score"])])
		_log("round won by " + round_winner)
		_play_sfx("spawn", pos, 0.0)


func _spawn() -> void:
	pos = Vector2(randf_range(80, ARENA.x - 80), randf_range(80, ARENA.y - 80))
	angle = randf_range(-PI, PI)
	speed = START_SPEED
	bank = 0.0
	hp = bot_hp if bot_mode else MAX_HP
	alive = true
	shield = SHIELD_SEC
	_send_state()
	_play_sfx("spawn", pos, -6.0)


func _update_me(delta: float) -> void:
	if not alive:
		respawn_left -= delta
		if respawn_left <= 0.0:
			_spawn()
		return
	shield = maxf(0.0, shield - delta)
	fire_cd = maxf(0.0, fire_cd - delta)

	var turn := 0.0
	var thrust := 0.0
	var fire := false
	if bot_mode:
		var c := _bot_controls()
		turn = c[0]
		thrust = c[1]
		fire = c[2]
	else:
		if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
			turn -= 1.0
		if Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
			turn += 1.0
		if Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
			thrust += 1.0
		if Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
			thrust -= 1.0
		fire = Input.is_physical_key_pressed(KEY_SPACE)
		if joy_index != -1 or not fire_touches.is_empty():
			var t := _touch_controls()
			turn = clampf(turn + float(t[0]), -1.0, 1.0)
			thrust = clampf(thrust + float(t[1]), -1.0, 1.0)
			fire = fire or bool(t[2])

	turn_rate = turn * TURN_SPEED
	angle = wrapf(angle + turn_rate * delta, -PI, PI)
	bank = lerpf(bank, turn, minf(1.0, delta * 5.0))
	speed = clampf(speed + thrust * ACCEL * delta, MIN_SPEED, MAX_SPEED)
	pos = _wrap(pos + Vector2.RIGHT.rotated(angle) * speed * delta)
	if fire and fire_cd <= 0.0 and round_over_left <= 0.0:
		_fire()


func _fire() -> void:
	fire_cd = FIRE_COOLDOWN
	bullet_seq += 1
	var bid := "%s-%d" % [my_id, bullet_seq]
	var start := _wrap(pos + Vector2.RIGHT.rotated(angle) * 30.0)
	_add_bullet(bid, my_id, start, angle)
	_broadcast("shot", {"id": my_id, "bid": bid, "x": start.x, "y": start.y, "a": angle})


func _add_bullet(bid: String, owner: String, start: Vector2, a: float) -> void:
	if owner == my_id or ai_planes.has(owner):
		own_shots[bid] = elapsed
	_play_sfx("shot", start, -8.0 if owner == my_id else -14.0)
	bullets.append({"bid": bid, "owner": owner, "pos": start, "vel": Vector2.RIGHT.rotated(a) * BULLET_SPEED, "life": BULLET_LIFE})


func _update_bullets(delta: float) -> void:
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["life"] = float(b["life"]) - delta
		b["pos"] = _wrap(b["pos"] + b["vel"] * delta)
		if float(b["life"]) <= 0.0:
			bullets.remove_at(i)
			continue
		if bot_mode and b["owner"] != my_id:
			stats["closest"] = minf(float(stats.get("closest", INF)), _wrap_delta(pos, b["pos"]).length())
		# 남이 쏜 총알이 나에게 닿았는지는 내가 판정합니다.
		if alive and shield <= 0.0 and b["owner"] != my_id and _wrap_delta(pos, b["pos"]).length() < HIT_RADIUS:
			bullets.remove_at(i)
			_take_hit(str(b["owner"]), str(b["bid"]))
			continue
		# 내가 방장이면 내 AI의 피격도 내가 판정합니다. AI끼리는 서로 맞지 않습니다.
		if ai_planes.has(b["owner"]):
			continue
		for aid in ai_planes:
			var ai: Dictionary = ai_planes[aid]
			if bool(ai["alive"]) and float(ai["shield"]) <= 0.0 and _wrap_delta(ai["pos"], b["pos"]).length() < HIT_RADIUS:
				bullets.remove_at(i)
				_ai_take_hit(str(aid), str(b["owner"]), str(b["bid"]))
				break


func _take_hit(shooter: String, bid: String) -> void:
	hp -= 1
	var killed := hp <= 0
	stats["hits_taken"] += 1
	_broadcast("hit", {"victim": my_id, "shooter": shooter, "bid": bid, "hp": hp, "killed": killed})
	_spark(pos)
	if killed:
		alive = false
		deaths += 1
		respawn_left = RESPAWN_SEC
		_explode(pos, my_color)
		_add_feed("%s ▶ %s 격추" % [_name_of(shooter), my_name])
		if ai_planes.has(shooter):
			ai_planes[shooter]["score"] = int(ai_planes[shooter]["score"]) + 1
		_log("shot down by " + _name_of(shooter))
	_send_state()


func _send_state() -> void:
	if not rt:
		return
	_broadcast("state", {
		"id": my_id, "name": my_name, "color": my_color.to_html(false),
		"x": snappedf(pos.x, 0.1), "y": snappedf(pos.y, 0.1), "a": snappedf(angle, 0.001),
		"v": snappedf(speed, 0.1), "w": snappedf(turn_rate, 0.01), "hp": hp, "alive": alive, "score": score, "deaths": deaths,
	})


# ---------------------------------------------------------------- 수신

func _on_broadcast(event: String, p: Dictionary) -> void:
	match event:
		"state":
			var id := _id(p.get("id"))
			if _is_human(id):
				stats["states"] += 1
				_upsert_peer(id, p)
		"shot":
			_on_shot(p)
		"hit":
			_on_hit(p)
		"ai":
			_on_ai_states(p)


# ---- 받은 값 검증. 누구나 채널에 메시지를 보낼 수 있으므로 타입·범위·개수를 모두 확인합니다.

func _num(v: Variant, fallback: float, lo := -INF, hi := INF) -> float:
	if (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT) or not is_finite(float(v)):
		return fallback
	return clampf(float(v), lo, hi)


func _flag(v: Variant, fallback: bool) -> bool:
	return bool(v) if typeof(v) == TYPE_BOOL else fallback


func _id(v: Variant) -> String:
	# id와 bid는 영문 소문자·숫자·- 로만 이루어진 짧은 문자열이어야 합니다. 아니면 ""를 돌려줍니다.
	if typeof(v) != TYPE_STRING:
		return ""
	var s: String = v
	return s if s.length() <= MAX_ID_LEN and id_regex.search(s) else ""


func _point(p: Dictionary) -> Variant:
	# x, y가 유한한 숫자일 때만 화면 안 좌표로, 아니면 null
	var x := _num(p.get("x"), NAN)
	var y := _num(p.get("y"), NAN)
	if is_nan(x) or is_nan(y):
		return null
	return _wrap(Vector2(x, y))


func _is_human(id: String) -> bool:
	# presence에 있는 다른 사람만 상대로 받습니다. 없는 id로 보낸 state로 가짜 비행기를 만들 수 없게 합니다.
	return id != "" and id != my_id and rt != null and rt.presence.has(id)


func _upsert_peer(id: String, p: Dictionary) -> bool:
	var target: Variant = _point(p)
	if target == null:
		return false
	if not peers.has(id) and peers.size() >= MAX_PEERS:
		return false
	var a := wrapf(_num(p.get("a"), 0.0), -PI, PI)
	var now_alive := _flag(p.get("alive"), true)
	var new_score := int(_num(p.get("score"), 0.0, 0.0, win_score))
	var peer: Dictionary
	if peers.has(id):
		peer = peers[id]
		if bot_mode and now_alive and bool(peer["alive"]):
			_record_prediction(peer, target)
		if now_alive and not bool(peer["alive"]):
			peer["pos"] = target
			peer["angle"] = a
		# 격추는 한 번에 하나씩 state로 알리므로 점수가 한꺼번에 2점 이상 오르면 받지 않습니다(새 판으로 내려가는 것은 허용).
		new_score = mini(new_score, int(peer["score"]) + 1)
	else:
		peer = {"pos": target, "angle": a}
		peers[id] = peer
		stats["peers_seen"] += 1
		_log("peer seen: " + str(p.get("name", id)))
	var nick := str(p.get("name", "?")).strip_edges().left(12)
	peer["name"] = nick if nick != "" else "?"
	peer["color"] = Color.from_string(str(p.get("color", "ffffff")).left(8), Color.WHITE)
	peer["target"] = target
	peer["lin_target"] = target
	peer["target_angle"] = a
	peer["lin_angle"] = a
	peer["speed"] = _num(p.get("v"), START_SPEED, MIN_SPEED, MAX_SPEED)
	# 선회 속도가 없으면(예전 버전) 0으로 보고 직선으로 예측합니다.
	peer["turn_rate"] = _num(p.get("w"), 0.0, -TURN_SPEED, TURN_SPEED)
	peer["hp"] = int(_num(p.get("hp"), MAX_HP, 0, MAX_HP))
	peer["alive"] = now_alive
	peer["score"] = new_score
	peer["last_seen"] = elapsed
	return true


func _record_prediction(peer: Dictionary, actual: Vector2) -> void:
	# 봇 점검용: 새 state가 왔을 때 예측 위치가 얼마나 빗나갔는지(곡선 예측 vs 예전 직선 예측) 셉니다.
	var n := int(stats.get("pred_n", 0)) + 1
	stats["pred_n"] = n
	for key in [["target", "pred_err"], ["lin_target", "lin_err"]]:
		var err := _wrap_delta(peer[key[0]], actual).length()
		stats[key[1]] = snappedf(float(stats.get(key[1], 0.0)) + (err - float(stats.get(key[1], 0.0))) / n, 0.01)
		stats[key[1] + "_max"] = snappedf(maxf(float(stats.get(key[1] + "_max", 0.0)), err), 0.1)


func _on_shot(p: Dictionary) -> void:
	var id := _id(p.get("id"))
	var bid := _id(p.get("bid"))
	var start: Variant = _point(p)
	# 쏜 쪽은 presence에 있는 사람이거나 이미 받은 AI여야 합니다.
	if bid == "" or start == null or not (_is_human(id) or (peers.has(id) and bool(peers[id].get("ai", false)))):
		return
	if bullets.size() >= MAX_BULLETS:
		return
	var count := 0
	for b in bullets:
		if b["owner"] == id:
			count += 1
	if count >= MAX_BULLETS_PER_OWNER:
		return
	stats["shots"] += 1
	_add_bullet(bid, id, start, wrapf(_num(p.get("a"), 0.0), -PI, PI))


func _prune_shot_memory() -> void:
	for bid in own_shots.keys():
		if elapsed - float(own_shots[bid]) > SHOT_MEMORY:
			own_shots.erase(bid)
	for bid in seen_hits.keys():
		if elapsed - float(seen_hits[bid]) > SHOT_MEMORY:
			seen_hits.erase(bid)


func _on_hit(p: Dictionary) -> void:
	var victim := _id(p.get("victim"))
	var shooter := _id(p.get("shooter"))
	var bid := _id(p.get("bid"))
	# 피해자는 내가 받은 상대여야 합니다. 나와 내 AI의 피격은 내가 직접 판정하므로 남이 보낸 것은 무시합니다.
	if victim == "" or shooter == "" or bid == "" or not peers.has(victim) or seen_hits.has(bid):
		return
	# 나 또는 내 AI가 쏜 총알이라면 실제로 최근에 쏜 bid인지 확인합니다. 한 발은 한 번만 맞습니다.
	var mine := shooter == my_id or ai_planes.has(shooter)
	if mine and not own_shots.has(bid):
		return
	own_shots.erase(bid)
	seen_hits[bid] = elapsed
	if shooter == my_id:
		stats["hits_given"] = int(stats.get("hits_given", 0)) + 1
	for i in range(bullets.size() - 1, -1, -1):
		if bullets[i]["bid"] == bid:
			bullets.remove_at(i)
	var peer: Dictionary = peers[victim]
	var was_alive := bool(peer["alive"])
	var left_hp := int(_num(p.get("hp"), 0, 0, MAX_HP))
	peer["hp"] = left_hp
	var where: Vector2 = peer["pos"]
	_spark(where)
	if _flag(p.get("killed"), false) and left_hp <= 0 and was_alive:
		peer["alive"] = false
		_explode(where, peer["color"])
		if shooter == my_id:
			score += 1
			stats["kills"] += 1
			_send_state()
		elif ai_planes.has(shooter):
			ai_planes[shooter]["score"] = int(ai_planes[shooter]["score"]) + 1
		_add_feed("%s ▶ %s 격추" % [_name_of(shooter), _name_of(victim)])


func _on_presence_joined(key: String, meta: Dictionary) -> void:
	if key != my_id:
		_add_feed("%s 입장" % str(meta.get("name", "?")).left(12))


func _on_presence_left(key: String, meta: Dictionary) -> void:
	if peers.has(key):
		peers.erase(key)
	# 나간 방장의 AI도 함께 치웁니다. 새 방장이 AI를 다시 띄웁니다.
	for id in peers.keys():
		if peers[id].get("owner", "") == key:
			peers.erase(id)
	if key != my_id:
		_add_feed("%s 퇴장" % str(meta.get("name", "?")).left(12))


func _update_peers(delta: float) -> void:
	for id in peers.keys():
		var peer: Dictionary = peers[id]
		if elapsed - float(peer["last_seen"]) > PEER_TIMEOUT:
			peers.erase(id)
			continue
		# 다음 state가 올 때까지 마지막 속도와 선회 속도로 곡선을 그리며 예측하고, 화면 위치는 부드럽게 따라갑니다.
		# 선회 중에 직선으로만 예측하면 state가 올 때마다 바깥으로 튀었다가 돌아와 끊겨 보입니다.
		if bool(peer["alive"]):
			peer["target_angle"] = wrapf(float(peer["target_angle"]) + float(peer.get("turn_rate", 0.0)) * delta, -PI, PI)
			peer["target"] = _wrap(peer["target"] + Vector2.RIGHT.rotated(float(peer["target_angle"])) * float(peer["speed"]) * delta)
			if bot_mode:
				peer["lin_target"] = _wrap(peer["lin_target"] + Vector2.RIGHT.rotated(float(peer["lin_angle"])) * float(peer["speed"]) * delta)
		var diff := _wrap_delta(peer["pos"], peer["target"])
		if diff.length() > 150.0:
			peer["pos"] = peer["target"]
		else:
			peer["pos"] = _wrap(peer["pos"] + diff * minf(1.0, delta * 10.0))
		var prev_angle := float(peer["angle"])
		peer["angle"] = lerp_angle(prev_angle, float(peer["target_angle"]), minf(1.0, delta * 12.0))
		# 받은 각도가 바뀌는 속도로 기울기를 추정합니다.
		var turn_rate := wrapf(float(peer["angle"]) - prev_angle, -PI, PI) / maxf(delta, 0.001)
		peer["bank"] = lerpf(float(peer.get("bank", 0.0)), clampf(turn_rate / TURN_SPEED, -1.0, 1.0), minf(1.0, delta * 5.0))


# ---------------------------------------------------------------- AI 적기
# 방장(presence 키가 가장 작은 사람)이 AI를 움직이고, "ai" 이벤트 하나에 모든 AI 상태를 담아 보냅니다.
# 다른 사람들은 AI를 일반 상대처럼 받아 그리고, AI 총알도 shot 이벤트로 받아 피격을 스스로 판정합니다.

func _humans() -> Array:
	var keys: Array = rt.presence.keys() if rt else []
	if not keys.has(my_id):
		keys.append(my_id)
	keys.sort()
	return keys


func _manage_ai() -> void:
	var humans := _humans()
	var want := ai_count if humans[0] == my_id else 0
	while ai_planes.size() > want:
		ai_planes.erase(ai_planes.keys().back())
	while ai_planes.size() < want:
		ai_seq += 1
		var ai := {
			"name": "[AI] " + str(AI_NAMES[ai_seq % AI_NAMES.size()]),
			"color": Color.from_hsv(randf_range(0.0, 0.08), 0.75, 0.95),
			"score": 0, "wobble": randf() * TAU, "fire_seq": 0,
		}
		ai_planes["%s-ai%d" % [my_id, ai_seq]] = ai
		_spawn_ai(ai)


func _spawn_ai(ai: Dictionary) -> void:
	# 사람 바로 옆에서 나오지 않도록 내 비행기와 떨어진 곳을 고릅니다.
	var at := Vector2.ZERO
	for i in 10:
		at = Vector2(randf_range(60, ARENA.x - 60), randf_range(60, ARENA.y - 60))
		if _wrap_delta(pos, at).length() > 350.0:
			break
	ai["pos"] = at
	ai["angle"] = randf_range(-PI, PI)
	ai["speed"] = 150.0
	ai["bank"] = 0.0
	ai["hp"] = MAX_HP
	ai["alive"] = true
	ai["shield"] = SHIELD_SEC
	ai["fire_cd"] = 2.0
	ai["respawn_left"] = 0.0


func _update_ai(delta: float) -> void:
	var lv: Dictionary = AI_LEVELS[clampi(ai_level, 0, AI_LEVELS.size() - 1)]
	for id in ai_planes:
		var ai: Dictionary = ai_planes[id]
		if not bool(ai["alive"]):
			ai["respawn_left"] = float(ai["respawn_left"]) - delta
			if float(ai["respawn_left"]) <= 0.0:
				_spawn_ai(ai)
			continue
		ai["shield"] = maxf(0.0, float(ai["shield"]) - delta)
		ai["fire_cd"] = float(ai["fire_cd"]) - delta
		var a := float(ai["angle"])
		var at: Vector2 = ai["pos"]
		var wobble := float(ai["wobble"])

		# 가장 가까운 사람(나 또는 다른 플레이어)을 노립니다.
		var target: Variant = null
		var best_d := INF
		var candidates: Array = []
		if alive:
			candidates.append({"pos": pos, "angle": angle, "speed": speed})
		for peer in peers.values():
			if bool(peer["alive"]) and not bool(peer.get("ai", false)):
				candidates.append(peer)
		for c in candidates:
			var d := _wrap_delta(at, c["pos"]).length()
			if d < best_d:
				best_d = d
				target = c

		var turn := sin(elapsed * 0.7 + wobble) * 0.6
		var thrust := 0.0
		var fire := false
		if target != null:
			var lead := Vector2.RIGHT.rotated(float(target["angle"])) * float(target["speed"]) * (best_d / BULLET_SPEED)
			var to := _wrap_delta(at, target["pos"] + lead)
			# 조준에 약간의 흔들림을 넣어 백발백중이 되지 않게 합니다.
			var diff := wrapf(to.angle() + sin(elapsed * 1.3 + wobble) * float(lv["wobble"]) - a, -PI, PI)
			turn = clampf(diff * 2.0, -1.0, 1.0)
			thrust = -1.0 if best_d < 200.0 else 0.4
			fire = absf(diff) < float(lv["cone"]) and best_d < AI_FIRE_RANGE

		# AI끼리 한 덩어리로 뭉치지 않도록 가까운 AI 반대쪽으로 방향을 틉니다.
		var away := Vector2.ZERO
		for other_id in ai_planes:
			if other_id != id and bool(ai_planes[other_id]["alive"]):
				var gap := _wrap_delta(at, ai_planes[other_id]["pos"])
				if gap.length() < 110.0:
					away -= gap.normalized()
		if away != Vector2.ZERO:
			turn = clampf(turn + clampf(wrapf(away.angle() - a, -PI, PI), -1.0, 1.0), -1.0, 1.0)

		ai["w"] = turn * float(lv["turn"])
		a = wrapf(a + float(ai["w"]) * delta, -PI, PI)
		ai["bank"] = lerpf(float(ai["bank"]), turn, minf(1.0, delta * 5.0))
		var v := clampf(float(ai["speed"]) + thrust * ACCEL * delta, MIN_SPEED, float(lv["speed"]))
		ai["angle"] = a
		ai["speed"] = v
		ai["pos"] = _wrap(at + Vector2.RIGHT.rotated(a) * v * delta)

		if fire and float(ai["fire_cd"]) <= 0.0 and round_over_left <= 0.0:
			ai["fire_cd"] = float(lv["cooldown"]) + randf() * 0.4
			ai["fire_seq"] = int(ai["fire_seq"]) + 1
			var bid := "%s-%d" % [id, ai["fire_seq"]]
			var start := _wrap(ai["pos"] + Vector2.RIGHT.rotated(a) * 30.0)
			_add_bullet(bid, str(id), start, a)
			_broadcast("shot", {"id": id, "bid": bid, "x": start.x, "y": start.y, "a": a})


func _ai_take_hit(aid: String, shooter: String, bid: String) -> void:
	own_shots.erase(bid)
	seen_hits[bid] = elapsed
	var ai: Dictionary = ai_planes[aid]
	ai["hp"] = int(ai["hp"]) - 1
	var killed := int(ai["hp"]) <= 0
	_broadcast("hit", {"victim": aid, "shooter": shooter, "bid": bid, "hp": ai["hp"], "killed": killed})
	_spark(ai["pos"])
	if killed:
		ai["alive"] = false
		ai["respawn_left"] = AI_RESPAWN_SEC
		_explode(ai["pos"], ai["color"])
		_add_feed("%s ▶ %s 격추" % [_name_of(shooter), str(ai["name"])])
		if shooter == my_id:
			score += 1
			stats["kills"] += 1
			_send_state()


func _send_ai() -> void:
	# AI가 모두 사라졌을 때도 빈 목록을 한 번 보내서 다른 사람 화면에서 지웁니다.
	if ai_planes.is_empty() and not ai_announced:
		return
	ai_announced = not ai_planes.is_empty()
	var list := []
	for id in ai_planes:
		var ai: Dictionary = ai_planes[id]
		var p: Vector2 = ai["pos"]
		list.append({
			"id": id, "name": ai["name"], "color": (ai["color"] as Color).to_html(false),
			"x": snappedf(p.x, 0.1), "y": snappedf(p.y, 0.1), "a": snappedf(float(ai["angle"]), 0.001),
			"v": snappedf(float(ai["speed"]), 0.1), "w": snappedf(float(ai.get("w", 0.0)), 0.01),
			"hp": ai["hp"], "alive": ai["alive"], "score": ai["score"],
		})
	_broadcast("ai", {"owner": my_id, "level": ai_level, "list": list})


func _on_ai_states(p: Dictionary) -> void:
	# AI는 방장(presence 키가 가장 작은 사람)이 보낸 것만 받습니다.
	var host_id := _id(p.get("owner"))
	if not _is_human(host_id) or _humans()[0] != host_id:
		return
	remote_ai_level = int(_num(p.get("level"), -1, -1, AI_LEVELS.size() - 1))
	var ids := {}
	var list: Variant = p.get("list", [])
	if typeof(list) == TYPE_ARRAY:
		for s in list.slice(0, AI_MAX_COUNT):
			if typeof(s) != TYPE_DICTIONARY:
				continue
			# AI id는 "방장id-aiN" 꼴이어야 합니다. 사람이나 다른 방장의 id를 덮어쓰지 못하게 합니다.
			var id := _id(s.get("id"))
			if not id.begins_with(host_id + "-ai"):
				continue
			if not _upsert_peer(id, s):
				continue
			ids[id] = true
			peers[id]["ai"] = true
			peers[id]["owner"] = host_id
	for id in peers.keys():
		if peers[id].get("owner", "") == host_id and not ids.has(id):
			peers.erase(id)


# ---------------------------------------------------------------- 보조

func _wrap(p: Vector2) -> Vector2:
	return Vector2(fposmod(p.x, ARENA.x), fposmod(p.y, ARENA.y))


func _wrap_delta(from: Vector2, to: Vector2) -> Vector2:
	var d := to - from
	if d.x > ARENA.x / 2:
		d.x -= ARENA.x
	elif d.x < -ARENA.x / 2:
		d.x += ARENA.x
	if d.y > ARENA.y / 2:
		d.y -= ARENA.y
	elif d.y < -ARENA.y / 2:
		d.y += ARENA.y
	return d


func _name_of(id: String) -> String:
	if id == my_id:
		return my_name
	if peers.has(id):
		return str(peers[id]["name"])
	if ai_planes.has(id):
		return str(ai_planes[id]["name"])
	if rt and rt.presence.has(id):
		return str(rt.presence[id].get("name", "?")).left(12)
	return "?"


func _color_of(id: String) -> Color:
	if id == my_id:
		return my_color
	if peers.has(id):
		return peers[id]["color"]
	if ai_planes.has(id):
		return ai_planes[id]["color"]
	return Color.WHITE


func _add_feed(text: String) -> void:
	feed.push_front({"text": text, "t": 5.0})
	if feed.size() > 5:
		feed.pop_back()


func _add_effect(at: Vector2, color: Color, dur: float, size: float) -> void:
	effects.append({"pos": at, "color": color, "t": 0.0, "dur": dur, "size": size})


func _update_effects(delta: float) -> void:
	_update_particles(delta)
	for i in range(effects.size() - 1, -1, -1):
		effects[i]["t"] = float(effects[i]["t"]) + delta
		if float(effects[i]["t"]) >= float(effects[i]["dur"]):
			effects.remove_at(i)
	for i in range(feed.size() - 1, -1, -1):
		feed[i]["t"] = float(feed[i]["t"]) - delta
		if float(feed[i]["t"]) <= 0.0:
			feed.remove_at(i)


func _bot_controls() -> Array:
	var best: Variant = null
	var best_d := INF
	# 오프라인 데모에서는 내가 방장이라 AI가 peers가 아닌 ai_planes에 있습니다.
	for peer in peers.values() + ai_planes.values():
		if bool(peer["alive"]):
			var d := _wrap_delta(pos, peer["pos"]).length()
			if d < best_d:
				best_d = d
				best = peer
	if best == null:
		return [0.5, 0.0, false]
	# 총알이 날아가는 동안 상대가 움직일 거리만큼 앞을 겨눕니다.
	var lead := Vector2.RIGHT.rotated(float(best["angle"])) * float(best["speed"]) * (best_d / BULLET_SPEED)
	var to := _wrap_delta(pos, best["pos"] + lead)
	var diff := wrapf(to.angle() - angle, -PI, PI)
	return [clampf(diff * 2.0, -1.0, 1.0), -1.0 if best_d < 250 else 0.5, absf(diff) < 0.6 and best_d < 600]


func _broadcast(event: String, payload: Dictionary) -> void:
	if rt:
		rt.send_broadcast(event, payload)


## 홍보 영상(promo/)에서 부릅니다. 네트워크 없이 내 비행기를 봇이 조종하고, 내가 방장이 되어 AI를 띄웁니다.
func start_demo(nick: String, ai_n: int, level: int, player_hp: int) -> void:
	demo_mode = true
	bot_mode = true
	bot_hp = player_hp
	ai_count = ai_n
	ai_level = level
	my_id = "demo-me"
	my_name = nick
	room = "demo"
	my_color = Color(0.45, 0.85, 1.0)
	menu_root.visible = false
	mode = Mode.PLAYING
	_spawn()


func _log(text: String) -> void:
	if bot_mode:
		print("[%s] %s" % [my_name, text])


func _finish_bot() -> void:
	if _args.has("screenshot"):
		get_viewport().get_texture().get_image().save_png(str(_args["screenshot"]))
	stats["score"] = score
	stats["deaths"] = deaths
	stats["ai_owned"] = ai_planes.size()
	stats["ai_seen"] = peers.values().filter(func(pr: Dictionary) -> bool: return bool(pr.get("ai", false))).size()
	print("[%s] RESULT %s" % [my_name, JSON.stringify(stats)])
	if rt:
		rt.leave()
	bot_mode = false
	get_tree().create_timer(0.3).timeout.connect(get_tree().quit)


# ---------------------------------------------------------------- 연출 (입체감)
# 위에서 내려다보는 시점에 비행기 그림자, 높이가 다른 두 층의 구름, 선회할 때의 기울기 음영을 더해
# 2D 화면이지만 하늘 높이 떠 있는 것처럼 보이게 합니다. 네트워크와는 무관합니다.

const SHADOW_OFFSET := Vector2(18, 26)  # 비행기 그림자 위치. 멀수록 높이 떠 보입니다.
const PLANE_SCALE := 1.35
const PLANE_LEFT := [
	Vector2(22, 0), Vector2(8, -3), Vector2(2, -17), Vector2(-5, -17), Vector2(-4, -3),
	Vector2(-13, -3), Vector2(-17, -9), Vector2(-21, -9), Vector2(-18, 0),
]
const PLANE_RIGHT := [
	Vector2(22, 0), Vector2(-18, 0), Vector2(-21, 9), Vector2(-17, 9), Vector2(-13, 3),
	Vector2(-4, 3), Vector2(-5, 17), Vector2(2, 17), Vector2(8, 3),
]
const PLANE_SPINE := [
	Vector2(20, 0), Vector2(6, -2.4), Vector2(-14, -1.6), Vector2(-17, 0), Vector2(-14, 1.6), Vector2(6, 2.4),
]
const SEA_TOP := Color(0.10, 0.36, 0.52)
const SEA_BOTTOM := Color(0.05, 0.20, 0.36)
const MAX_PARTICLES := 700


func _build_scenery() -> void:
	# 지형은 모든 사람에게 같게 보이도록 고정된 시드로 만듭니다.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 70:
		glints.append(Vector3(rng.randf() * ARENA.x, rng.randf() * ARENA.y, rng.randf() * TAU))
	var island_spots := [Vector2(260, 200), Vector2(930, 520), Vector2(1080, 170)]
	for spot in island_spots:
		var blobs := []
		for j in rng.randi_range(4, 7):
			blobs.append(Vector3(rng.randf_range(-60, 60), rng.randf_range(-35, 35), rng.randf_range(26, 48)))
		islands.append({"pos": spot, "blobs": blobs})
	for i in 11:
		var puffs := []
		for j in rng.randi_range(4, 7):
			puffs.append(Vector3(rng.randf_range(-55, 55), rng.randf_range(-16, 16), rng.randf_range(16, 34)))
		var high := i % 3 == 0
		clouds.append({
			"pos": Vector2(rng.randf() * ARENA.x, rng.randf() * ARENA.y),
			"puffs": puffs, "high": high, "speed": 20.0 if high else 8.0,
		})


func _update_scenery(delta: float) -> void:
	for c in clouds:
		var p: Vector2 = c["pos"]
		p.x += float(c["speed"]) * delta
		if p.x > ARENA.x + 120.0:
			p.x = -120.0
		c["pos"] = p
		if c.has("node"):
			(c["node"] as Node2D).position = p
	if glint_layer:
		glint_layer.queue_redraw()


func _visible_planes() -> Array:
	# 그리기와 연출에 쓰는 공통 형식으로 살아 있는 비행기를 모읍니다.
	var list := []
	for id in peers:
		var p: Dictionary = peers[id]
		if bool(p["alive"]):
			list.append({
				"id": str(id), "pos": p["pos"], "angle": float(p["angle"]), "bank": float(p.get("bank", 0.0)),
				"color": p["color"], "name": str(p["name"]), "hp": int(p["hp"]), "shield": false, "me": false,
			})
	for id in ai_planes:
		var ai: Dictionary = ai_planes[id]
		if bool(ai["alive"]):
			list.append({
				"id": str(id), "pos": ai["pos"], "angle": float(ai["angle"]), "bank": float(ai["bank"]),
				"color": ai["color"], "name": str(ai["name"]), "hp": int(ai["hp"]),
				"shield": float(ai["shield"]) > 0.0, "me": false,
			})
	if alive:
		list.append({
			"id": my_id, "pos": pos, "angle": angle, "bank": bank, "color": my_color,
			"name": my_name, "hp": hp, "shield": shield > 0.0, "me": true,
		})
	return list


func _update_trails(delta: float) -> void:
	trail_left -= delta
	smoke_left -= delta
	var sample := trail_left <= 0.0
	var smoke := smoke_left <= 0.0
	if sample:
		trail_left = 0.04
	if smoke:
		smoke_left = 0.08
	if not sample and not smoke:
		return
	var seen := {}
	for pl in _visible_planes():
		var id: String = pl["id"]
		seen[id] = true
		if sample:
			_push_trail(id, pl["pos"], float(pl["angle"]), float(pl["bank"]))
		# 체력이 절반 이하면 꼬리에서 연기가 납니다. 한 칸 남으면 검은 연기.
		if smoke and int(pl["hp"]) * 2 <= MAX_HP and particles.size() < MAX_PARTICLES:
			var tail: Vector2 = pl["pos"] + Vector2(-18 * PLANE_SCALE, 0).rotated(float(pl["angle"]))
			var col := Color(0.16, 0.16, 0.18) if int(pl["hp"]) <= 1 else Color(0.78, 0.78, 0.8)
			particles.append({"pos": tail, "vel": Vector2(randf_range(-8, 8), randf_range(-8, 8)), "life": 0.9, "max": 0.9, "size": 5.0, "color": col, "smoke": true})
	if sample:
		for id in trails.keys():
			if not seen.has(id):
				trails.erase(id)


func _push_trail(id: String, at: Vector2, a: float, b: float) -> void:
	var t: Array = trails.get(id, [])
	var half := 17.0 * PLANE_SCALE * _wing_scale(b)
	t.append([at + Vector2(-3, -half).rotated(a), at + Vector2(-3, half).rotated(a)])
	if t.size() > 16:
		t.pop_front()
	trails[id] = t


func _wing_scale(b: float) -> float:
	# 기울면 날개가 화면에서 짧아 보입니다.
	return 1.0 - 0.4 * absf(b)


# ---------------------------------------------------------------- 효과음
# 외부 음원 없이 짧은 소리를 코드로 합성합니다. 나에게서 먼 곳의 소리는 작게 들립니다.

const SFX_RATE := 22050


func _build_sfx() -> void:
	var phase := [0.0]
	sfx["shot"] = _synth(0.1, func(x: float) -> float:
		phase[0] += TAU * (320.0 + 900.0 * exp(-x * 45.0)) / SFX_RATE
		return (sin(phase[0]) * 0.5 + _sfx_noise() * 0.18) * exp(-x * 38.0))
	sfx["hit"] = _synth(0.14, func(x: float) -> float:
		return _sfx_noise() * exp(-x * 30.0) * 0.45 + sin(TAU * 1500.0 * x) * exp(-x * 45.0) * 0.25)
	var lp := [0.0]
	sfx["boom"] = _synth(0.8, func(x: float) -> float:
		lp[0] += (_sfx_noise() - lp[0]) * 0.12
		return sin(TAU * 52.0 * x) * exp(-x * 5.0) * 0.7 + lp[0] * exp(-x * 6.0) * 1.6)
	var ph2 := [0.0]
	sfx["spawn"] = _synth(0.25, func(x: float) -> float:
		ph2[0] += TAU * (500.0 + 2000.0 * x) / SFX_RATE
		return sin(ph2[0]) * sin(PI * x / 0.25) * 0.28)
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		sfx_players.append(p)


func _synth(length: float, f: Callable) -> AudioStreamWAV:
	var n := int(length * SFX_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	for k in n:
		var v: float = f.call(float(k) / SFX_RATE)
		data.encode_s16(k * 2, int(tanh(v) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SFX_RATE
	wav.data = data
	return wav


func _sfx_noise() -> float:
	sfx_seed = (sfx_seed * 1103515245 + 12345) & 0x7fffffff
	return float(sfx_seed) / 1073741824.0 - 1.0


func _play_sfx(sound: String, at: Vector2, base_db: float) -> void:
	# 홍보 영상(자체 사운드가 있음)과 헤드리스 봇에서는 소리를 내지 않습니다.
	if muted or demo_mode or bot_mode or mode != Mode.PLAYING:
		return
	var dist := _wrap_delta(pos, at).length()
	var p: AudioStreamPlayer = sfx_players[sfx_next]
	sfx_next = (sfx_next + 1) % sfx_players.size()
	p.stream = sfx[sound]
	p.volume_db = base_db - clampf(dist / 50.0, 0.0, 20.0)
	p.pitch_scale = randf_range(0.94, 1.06)
	p.play()


func _toggle_mute() -> void:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
	_save_settings()
	if mode == Mode.PLAYING:
		_add_feed("소리 끔 (M)" if muted else "소리 켬 (M)")


func _spark(at: Vector2) -> void:
	_play_sfx("hit", at, -6.0)
	for i in 8:
		var dir := Vector2.RIGHT.rotated(randf() * TAU)
		particles.append({"pos": at, "vel": dir * randf_range(60, 160), "life": 0.35, "max": 0.35, "size": 2.5, "color": Color(1, 0.85, 0.4), "smoke": false})


func _explode(at: Vector2, color: Color) -> void:
	_play_sfx("boom", at, -1.0)
	_add_effect(at, Color(1, 0.75, 0.35), 0.6, 70)
	for i in 18:
		var dir := Vector2.RIGHT.rotated(randf() * TAU)
		var life := randf_range(0.5, 1.0)
		particles.append({"pos": at, "vel": dir * randf_range(80, 260), "life": life, "max": life, "size": 3.0, "color": Color(1, randf_range(0.5, 0.9), 0.3), "smoke": false})
	for i in 5:
		var dir := Vector2.RIGHT.rotated(randf() * TAU)
		particles.append({"pos": at, "vel": dir * randf_range(50, 150), "life": 0.9, "max": 0.9, "size": 4.0, "color": color, "smoke": false})
	for i in 10:
		var dir := Vector2.RIGHT.rotated(randf() * TAU)
		var life := randf_range(1.2, 1.8)
		particles.append({"pos": at, "vel": dir * randf_range(10, 50), "life": life, "max": life, "size": randf_range(10, 16), "color": Color(0.3, 0.3, 0.32), "smoke": true})


func _update_particles(delta: float) -> void:
	var damp := pow(0.15, delta)
	for i in range(particles.size() - 1, -1, -1):
		var pt: Dictionary = particles[i]
		pt["life"] = float(pt["life"]) - delta
		if float(pt["life"]) <= 0.0:
			particles.remove_at(i)
			continue
		pt["pos"] = pt["pos"] + pt["vel"] * delta
		pt["vel"] = pt["vel"] * damp


# ---------------------------------------------------------------- 그리기

func _draw() -> void:
	# 바다·섬·낮은 구름은 _build_layers의 자식 노드가 그립니다.

	var planes := _visible_planes() if mode == Mode.PLAYING else []
	for pl in planes:
		_draw_plane_shadow(pl)
	for t in trails.values():
		_draw_trail(t)
	for pt in particles:
		if bool(pt["smoke"]):
			var k := float(pt["life"]) / float(pt["max"])
			var c: Color = pt["color"]
			draw_circle(pt["pos"], float(pt["size"]) * (1.0 + (1.0 - k) * 1.6), Color(c.r, c.g, c.b, 0.4 * k))
	if mode == Mode.PLAYING:
		for b in bullets:
			_draw_bullet(b)
	for pl in planes:
		_draw_plane(pl)
	for pt in particles:
		if not bool(pt["smoke"]):
			var k := float(pt["life"]) / float(pt["max"])
			var c: Color = pt["color"]
			draw_circle(pt["pos"], float(pt["size"]) * k + 0.5, Color(c.r, c.g, c.b, k))
	for e in effects:
		var k := float(e["t"]) / float(e["dur"])
		var c: Color = e["color"]
		draw_circle(e["pos"], float(e["size"]) * (0.25 + k * 0.5), Color(c.r, c.g, c.b, 0.45 * (1.0 - k)))
		draw_arc(e["pos"], float(e["size"]) * k, 0, TAU, 40, Color(1, 1, 1, 0.9 * (1.0 - k)), 2.5, true)

	# 높은 구름은 비행기 위를 지나가며 살짝 가립니다.
	for c in clouds:
		if bool(c["high"]):
			_draw_cloud(self, c["pos"], c, true)
	if not demo_mode:
		_draw_vignette()

	if mode == Mode.PLAYING:
		# 이름표가 겹치면 위로 한 줄씩 올립니다. 내 이름표가 먼저 자리를 잡습니다.
		var ordered := planes.duplicate()
		ordered.sort_custom(func(l: Dictionary, r: Dictionary) -> bool: return bool(l["me"]) and not bool(r["me"]))
		var placed: Array = []
		for pl in ordered:
			var label := _label_text(pl)
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 8.0
			var at: Vector2 = pl["pos"]
			var r := Rect2(at.x - w / 2, at.y - 54, w, 17)
			var dy := 0.0
			for attempt in 4:
				var hit := false
				for q in placed:
					if (q as Rect2).intersects(r):
						hit = true
						break
				if not hit:
					break
				r.position.y -= 17.0
				dy -= 17.0
			placed.append(r)
			_draw_plane_label(pl, dy)
		if not demo_mode:
			_draw_hud()


# 바다·섬·구름은 원을 수백 개 그려야 해서 매 프레임 다시 그리면 웹에서 프레임이 밀립니다.
# 그래서 main 아래 z_index -1 자식 노드에 한 번만 그려 두고(CanvasItem은 queue_redraw 전까지 그린 것을 재사용),
# 구름은 노드 위치만 옮깁니다. 같은 z에서는 노드 순서대로 그려지므로 바다 → 물결 → 섬 → 낮은 구름 순서입니다.
func _build_layers() -> void:
	_add_layer(_draw_sea_base)
	glint_layer = _add_layer(_draw_glints)
	_add_layer(_draw_islands)
	for c in clouds:
		if not bool(c["high"]):
			var n := Node2D.new()
			n.z_index = -1
			n.position = c["pos"]
			n.draw.connect(_draw_cloud.bind(n, Vector2.ZERO, c, false))
			add_child(n)
			c["node"] = n


func _add_layer(draw_fn: Callable) -> Node2D:
	var n := Node2D.new()
	n.z_index = -1
	n.draw.connect(draw_fn.bind(n))
	add_child(n)
	return n


func _draw_sea_base(ci: CanvasItem) -> void:
	ci.draw_polygon(
		PackedVector2Array([Vector2.ZERO, Vector2(ARENA.x, 0), ARENA, Vector2(0, ARENA.y)]),
		PackedColorArray([SEA_TOP, SEA_TOP.lerp(SEA_BOTTOM, 0.3), SEA_BOTTOM, SEA_BOTTOM.lerp(SEA_TOP, 0.2)]))


func _draw_glints(ci: CanvasItem) -> void:
	# 물결 반짝임만 움직이므로 이 층만 매 프레임 다시 그립니다.
	for g in glints:
		var a := 0.05 + 0.1 * (0.5 + 0.5 * sin(elapsed * 1.6 + g.z))
		var x := fposmod(g.x + elapsed * 5.0, ARENA.x)
		ci.draw_line(Vector2(x - 6, g.y), Vector2(x + 6, g.y), Color(1, 1, 1, a), 1.5)


func _draw_islands(ci: CanvasItem) -> void:
	# 섬: 얕은 바다 → 모래 → 숲 → 볕 드는 쪽 순서로 겹쳐 그립니다.
	for isl in islands:
		var c: Vector2 = isl["pos"]
		for bl in isl["blobs"]:
			ci.draw_circle(c + Vector2(bl.x, bl.y), bl.z + 24, Color(0.4, 0.75, 0.78, 0.3))
		for bl in isl["blobs"]:
			ci.draw_circle(c + Vector2(bl.x, bl.y), bl.z + 7, Color(0.86, 0.8, 0.6))
		for bl in isl["blobs"]:
			ci.draw_circle(c + Vector2(bl.x, bl.y), bl.z, Color(0.25, 0.5, 0.3))
		for bl in isl["blobs"]:
			ci.draw_circle(c + Vector2(bl.x - bl.z * 0.25, bl.y - bl.z * 0.3), bl.z * 0.55, Color(0.34, 0.6, 0.35))


func _draw_cloud(ci: CanvasItem, p: Vector2, c: Dictionary, high: bool) -> void:
	# p는 ci 기준 구름 중심입니다. 낮은 구름은 자기 노드 원점(0, 0), 높은 구름은 main 기준 위치를 받습니다.
	if not high:
		for pf in c["puffs"]:
			ci.draw_circle(p + Vector2(pf.x, pf.y) + Vector2(40, 52), pf.z, Color(0, 0.05, 0.1, 0.12))
	var alpha := 0.2 if high else 0.75
	# 바깥쪽에 옅은 테두리를 한 겹 더 그려 구름 가장자리를 부드럽게 합니다.
	for pf in c["puffs"]:
		ci.draw_circle(p + Vector2(pf.x, pf.y), pf.z * 1.18, Color(0.84, 0.89, 0.95, alpha * 0.3))
	for pf in c["puffs"]:
		ci.draw_circle(p + Vector2(pf.x, pf.y), pf.z, Color(0.84, 0.89, 0.95, alpha * 0.8))
	for pf in c["puffs"]:
		ci.draw_circle(p + Vector2(pf.x - pf.z * 0.2, pf.y - pf.z * 0.25), pf.z * 0.7, Color(1, 1, 1, alpha * 0.8))


func _draw_vignette() -> void:
	var e := Color(0, 0.02, 0.06, 0.45)
	var z := Color(0, 0.02, 0.06, 0.0)
	var w := ARENA.x
	var h := ARENA.y
	var bw := 110.0
	_quad(Vector2(0, 0), Vector2(w, 0), Vector2(w, bw), Vector2(0, bw), e, e, z, z)
	_quad(Vector2(0, h - bw), Vector2(w, h - bw), Vector2(w, h), Vector2(0, h), z, z, e, e)
	_quad(Vector2(0, 0), Vector2(bw, 0), Vector2(bw, h), Vector2(0, h), e, z, z, e)
	_quad(Vector2(w - bw, 0), Vector2(w, 0), Vector2(w, h), Vector2(w - bw, h), z, e, e, z)


func _quad(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, c0: Color, c1: Color, c2: Color, c3: Color) -> void:
	draw_polygon(PackedVector2Array([p0, p1, p2, p3]), PackedColorArray([c0, c1, c2, c3]))


func _shape(src: Array, at: Vector2, a: float, ws: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in src:
		out.append(at + (Vector2(v.x, v.y * ws) * PLANE_SCALE).rotated(a))
	return out


func _shade(c: Color, k: float) -> Color:
	return c.lightened(k) if k >= 0.0 else c.darkened(-k)


func _draw_plane_shadow(pl: Dictionary) -> void:
	var ws := _wing_scale(float(pl["bank"])) * 0.85
	var pts := PackedVector2Array()
	for v in PLANE_SHAPE:
		pts.append(pl["pos"] + SHADOW_OFFSET + (Vector2(v.x * 0.85, v.y * ws) * PLANE_SCALE).rotated(float(pl["angle"])))
	draw_colored_polygon(pts, Color(0, 0.04, 0.1, 0.3))


func _draw_plane(pl: Dictionary) -> void:
	var at: Vector2 = pl["pos"]
	var a := float(pl["angle"])
	var b := clampf(float(pl["bank"]), -1.0, 1.0)
	var color: Color = pl["color"]
	var ws := _wing_scale(b)
	# 빛이 왼쪽 위에서 온다고 보고, 선회 방향으로 내려간 날개는 어둡게 칠합니다.
	draw_colored_polygon(_shape(PLANE_LEFT, at, a, ws), _shade(color, 0.22 + 0.3 * b))
	draw_colored_polygon(_shape(PLANE_RIGHT, at, a, ws), _shade(color, -0.12 - 0.3 * b))
	draw_colored_polygon(_shape(PLANE_SPINE, at, a, 1.0), _shade(color, 0.45))
	var outline := _shape(PLANE_SHAPE, at, a, ws)
	outline.append(outline[0])
	draw_polyline(outline, color.darkened(0.6), 1.2, true)
	# 조종석 유리와 반사광
	draw_circle(at + (Vector2(8, 0) * PLANE_SCALE).rotated(a), 3.4 * PLANE_SCALE, Color(0.12, 0.2, 0.32))
	draw_circle(at + (Vector2(9, -1) * PLANE_SCALE).rotated(a), 1.3 * PLANE_SCALE, Color(0.8, 0.95, 1, 0.8))
	# 엔진 불꽃
	var flame := 0.6 + 0.4 * sin(elapsed * 40.0 + at.x)
	draw_circle(at + (Vector2(-19, 0) * PLANE_SCALE).rotated(a), (2.5 + flame) * PLANE_SCALE, Color(1, 0.65, 0.25, 0.75))
	draw_circle(at + (Vector2(-19, 0) * PLANE_SCALE).rotated(a), 1.4 * PLANE_SCALE, Color(1, 0.95, 0.8))
	if bool(pl["shield"]):
		var pulse := 0.35 + 0.2 * sin(elapsed * 8.0)
		draw_circle(at, 38, Color(0.55, 0.85, 1.0, pulse * 0.25))
		draw_arc(at, 38, 0, TAU, 40, Color(0.55, 0.85, 1.0, pulse), 2.0, true)


func _label_text(pl: Dictionary) -> String:
	return str(pl["name"]) + (" (나)" if bool(pl["me"]) else "")


func _draw_plane_label(pl: Dictionary, dy: float) -> void:
	var at: Vector2 = pl["pos"]
	var label := _label_text(pl)
	if dy < 0.0:
		# 밀려 올라간 이름표는 기체와 이어지는 가는 선을 그립니다.
		draw_line(at + Vector2(0, -36 + dy), at + Vector2(0, -30), Color(1, 1, 1, 0.25), 1.0)
	_text(at + Vector2(-90, -40 + dy), label, 14, Color(1, 1, 1, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 180)
	var hp_value := int(pl["hp"])
	var x0 := at.x - (MAX_HP * 11 - 2) / 2.0
	draw_rect(Rect2(x0 - 2, at.y + 31, MAX_HP * 11 + 2, 7), Color(0, 0, 0, 0.35))
	for i in MAX_HP:
		var c := Color(1, 1, 1, 0.18)
		if i < hp_value:
			c = Color(1, 0.55, 0.35) if hp_value * 2 <= MAX_HP else Color(0.45, 1.0, 0.55)
		draw_rect(Rect2(x0 + i * 11, at.y + 32, 9, 5), c)


func _draw_trail(t: Array) -> void:
	var n := t.size()
	for side in 2:
		for i in range(1, n):
			var p0: Vector2 = t[i - 1][side]
			var p1: Vector2 = t[i][side]
			if p0.distance_to(p1) > 60.0:
				continue  # 화면 끝을 넘어간 구간
			var k := float(i) / n
			draw_line(p0, p1, Color(1, 1, 1, 0.28 * k), 0.6 + 1.4 * k)


func _draw_bullet(b: Dictionary) -> void:
	var p: Vector2 = b["pos"]
	var dir := (b["vel"] as Vector2).normalized()
	var c := _color_of(str(b["owner"])).lightened(0.5)
	draw_line(p - dir * 14, p, Color(c.r, c.g, c.b, 0.35), 5.0)
	draw_line(p - dir * 9, p, Color(1, 1, 0.85, 0.95), 2.0)
	draw_circle(p, 2.0, Color.WHITE)


func _text(at: Vector2, text: String, size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, at + Vector2(1, 1.5), text, align, width, size, Color(0, 0, 0, 0.55 * color.a))
	draw_string(font, at, text, align, width, size, color)


func _draw_hud() -> void:
	var shown_ai := ai_planes.size()
	for peer in peers.values():
		if bool(peer.get("ai", false)):
			shown_ai += 1
	var level := ai_level if not ai_planes.is_empty() else remote_ai_level
	var ai_text := "AI %d대" % shown_ai
	if shown_ai > 0 and level >= 0 and level < AI_LEVELS.size():
		ai_text += " (%s)" % AI_LEVELS[level]["name"]

	# 휴대폰에서는 HUD를 hud_k배로 키웁니다. 구석에 붙은 상자는 그 구석을 기준으로 키워 화면 밖으로 나가지 않게 합니다.
	var k := hud_k
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	var info := "방 %s   ·   접속 %d명   ·   %s" % [room, _humans().size(), ai_text]
	var info_w := font.get_string_size(info, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_style_box(hud_box, Rect2(12, 10, info_w + 32, 34))
	_text(Vector2(28, 33), info, 16, Color(0.92, 0.96, 1))
	var mine := "격추 %d   추락 %d" % [score, deaths]
	var mine_w := font.get_string_size(mine, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	draw_style_box(hud_box, Rect2(12, 50, mine_w + 32, 36))
	_text(Vector2(28, 75), mine, 18, Color(1, 0.86, 0.45))
	var y := 112.0
	for f in feed:
		_text(Vector2(18, y), str(f["text"]), 15, Color(1, 1, 1, clampf(float(f["t"]), 0.0, 1.0)))
		y += 22.0

	draw_set_transform(Vector2(ARENA.x * (1.0 - k), 0.0), 0.0, Vector2(k, k))
	var board := _board()
	var bx := ARENA.x - 252.0
	draw_style_box(hud_box, Rect2(bx, 10, 240, 44 + board.size() * 26))
	_text(Vector2(bx + 16, 36), "점수판", 15, Color(0.7, 0.82, 1.0))
	_text(Vector2(bx + 120, 36), "목표 %d격추" % win_score, 13, Color(1, 0.86, 0.45, 0.85), HORIZONTAL_ALIGNMENT_RIGHT, 104)
	var row := 64.0
	for entry in board:
		if bool(entry["me"]):
			draw_rect(Rect2(bx + 6, row - 18, 228, 24), Color(1, 1, 1, 0.08))
		draw_circle(Vector2(bx + 20, row - 6), 5, entry["color"])
		_text(Vector2(bx + 32, row), str(entry["name"]), 15, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, 150)
		_text(Vector2(bx + 180, row), str(entry["score"]), 15, Color(1, 0.86, 0.45), HORIZONTAL_ALIGNMENT_RIGHT, 44)
		row += 26.0

	draw_set_transform(ARENA / 2.0 * (1.0 - k), 0.0, Vector2(k, k))
	if round_over_left > 0.0:
		var winner_text := "%s 승리!" % round_winner
		draw_style_box(hud_box, Rect2(ARENA.x / 2 - 300, ARENA.y / 2 - 150, 600, 120))
		_text(Vector2(0, ARENA.y / 2 - 92), winner_text, 40, Color(1, 0.86, 0.45), HORIZONTAL_ALIGNMENT_CENTER, ARENA.x)
		_text(Vector2(0, ARENA.y / 2 - 50), "%.0f초 뒤 새 판이 시작됩니다" % ceilf(round_over_left), 18, Color(0.9, 0.95, 1.0), HORIZONTAL_ALIGNMENT_CENTER, ARENA.x)
	if not alive:
		draw_style_box(hud_box, Rect2(ARENA.x / 2 - 240, ARENA.y / 2 - 42, 480, 64))
		_text(Vector2(0, ARENA.y / 2), "격추되었습니다! %.1f초 뒤 다시 출격" % maxf(respawn_left, 0.0), 24, Color(1, 0.68, 0.55), HORIZONTAL_ALIGNMENT_CENTER, ARENA.x)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if touch_mode:
		_draw_touch_controls()
	else:
		_text(Vector2(18, ARENA.y - 18), "←→ / A D 회전    ↑↓ / W S 속도    Space 발사    L 초대 링크    M 소리 %s    Esc 두 번: 나가기" % ("꺼짐" if muted else "켜짐"), 14, Color(1, 1, 1, 0.7))


func _draw_touch_controls() -> void:
	# 조이스틱: 잡고 있으면 손가락을 댄 자리에, 아니면 기본 자리에 흐리게 보입니다.
	var held := joy_index != -1
	var base := joy_origin if held else JOY_HOME
	draw_circle(base, JOY_RADIUS, Color(1, 1, 1, 0.10 if held else 0.05))
	draw_arc(base, JOY_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.35 if held else 0.18), 3.0, true)
	draw_circle(base + joy_vec, 38, Color(1, 1, 1, 0.45 if held else 0.18))
	if not held:
		_text(base + Vector2(-JOY_RADIUS, JOY_RADIUS + 30), "조종", 22, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_CENTER, JOY_RADIUS * 2.0)

	var firing := not fire_touches.is_empty()
	draw_circle(FIRE_HOME, FIRE_RADIUS, Color(1, 0.56, 0.22, 0.5 if firing else 0.22))
	draw_arc(FIRE_HOME, FIRE_RADIUS, 0, TAU, 48, Color(1, 0.8, 0.55, 0.8 if firing else 0.45), 3.0, true)
	_text(FIRE_HOME + Vector2(-FIRE_RADIUS, 10), "발사", 30, Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER, FIRE_RADIUS * 2.0)

	var labels := {"sound": "소리 끔" if muted else "소리 켬", "invite": "초대", "leave": "나가기"}
	for i in TOUCH_BUTTONS.size():
		var r := _touch_button_rect(i)
		draw_style_box(hud_box, r)
		_text(Vector2(r.position.x, r.position.y + 36), labels[TOUCH_BUTTONS[i]], 22, Color(0.92, 0.96, 1), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# 처음 12초 동안만 조작법을 알려 줍니다.
	if elapsed - joined_at < 12.0:
		var a := clampf(12.0 - (elapsed - joined_at), 0.0, 1.0)
		_text(Vector2(0, ARENA.y - 96), "왼쪽 끌기: 조종(멀리 밀면 빨라요) · 오른쪽 누르기: 발사", 22, Color(1, 0.9, 0.6, a), HORIZONTAL_ALIGNMENT_CENTER, ARENA.x)
