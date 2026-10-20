extends Node2D
## SKY DUEL: Supabase Realtime 실시간 공중전.
## 각 클라이언트는 자기 비행기와 자기 총알만 직접 움직이고, 피격 판정은 맞은 쪽(피해자)이 내립니다.
##   state 이벤트: 내 위치·체력·점수 (초당 SEND_HZ회)
##   shot  이벤트: 총알 발사 (받는 쪽이 같은 궤적을 시뮬레이션)
##   hit   이벤트: 피격 알림 (격추면 쏜 사람이 자기 점수를 올림)

const RealtimeClient = preload("res://realtime_client.gd")

const SUPABASE_URL := "https://dyfieegfgskszpyldhzs.supabase.co"
const SUPABASE_KEY := "sb_publishable_6CYWcAoFrPU3LZ3MmoKgPA_uOfs8_MP"
const CHANNEL_PREFIX := "skyduel-"

const ARENA := Vector2(1280, 720)
const TURN_SPEED := 3.2
const MIN_SPEED := 140.0
const MAX_SPEED := 340.0
const ACCEL := 220.0
const BULLET_SPEED := 650.0
const BULLET_LIFE := 1.1
const FIRE_COOLDOWN := 0.2
const MAX_HP := 3
const HIT_RADIUS := 16.0
const RESPAWN_SEC := 2.0
const SHIELD_SEC := 2.0
const SEND_HZ := 10.0
const PEER_TIMEOUT := 6.0
const AI_MAX_COUNT := 8
const AI_RESPAWN_SEC := 3.0
# 난이도별 AI 성능. turn: 선회 속도, speed: 최고 속도, cooldown: 발사 간격(초),
# wobble: 조준 흔들림(라디안), cone: 이 각도 안에 들어오면 발사
const AI_LEVELS := [
	{"name": "쉬움", "turn": 1.8, "speed": 240.0, "cooldown": 0.9, "wobble": 0.3, "cone": 0.2},
	{"name": "보통", "turn": 2.4, "speed": 290.0, "cooldown": 0.55, "wobble": 0.15, "cone": 0.25},
	{"name": "어려움", "turn": 3.0, "speed": 330.0, "cooldown": 0.35, "wobble": 0.06, "cone": 0.3},
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

var bullets: Array = []      # { bid, owner, pos, vel, life }
var peers: Dictionary = {}   # id -> { name, color, pos, target, angle, target_angle, speed, hp, alive, score, last_seen }
var ai_planes: Dictionary = {}  # 내가 방장일 때 직접 움직이는 AI. id -> { name, color, pos, angle, speed, hp, alive, shield, fire_cd, respawn_left, score, wobble }
var ai_seq := 0
var ai_announced := false
var ai_count := 3            # 메뉴에서 정한 AI 수. 여럿이 할 때는 방장의 설정을 따릅니다.
var ai_level := 1            # AI_LEVELS 인덱스
var remote_ai_level := -1    # 방장이 다른 사람일 때 받은 난이도(점수판 표시용)
var effects: Array = []      # { pos, color, t, dur, size }
var feed: Array = []         # { text, t }
var stars: Array = []

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
var bot_hp := MAX_HP
var _args: Dictionary = {}
var quit_after := 0.0
var elapsed := 0.0
var stats := {"joined": false, "peers_seen": 0, "states": 0, "shots": 0, "hits_taken": 0, "kills": 0}


func _ready() -> void:
	randomize()
	font = _make_font()
	for i in 90:
		stars.append(Vector3(randf() * ARENA.x, randf() * ARENA.y, randf()))
	_build_menu()
	var args := _parse_args()
	_args = args
	quit_after = float(args.get("quit-after", "0"))
	if args.has("bot"):
		bot_mode = true
		if quit_after <= 0.0:
			quit_after = 20.0
		bot_hp = int(args.get("hp", str(MAX_HP)))
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

func _build_menu() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 20

	menu_root = CenterContainer.new()
	menu_root.theme = theme
	menu_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(menu_root)

	var panel := PanelContainer.new()
	menu_root.add_child(panel)
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
	title.add_theme_font_size_override("font_size", 48)
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
	box.add_child(_label("←→ / A D 회전   ↑↓ / W S 속도\nSpace 발사   Esc 나가기", 15, Color(0.75, 0.75, 0.8)))
	_load_settings()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		name_edit.text = str(cfg.get_value("menu", "name", name_edit.text))
		room_edit.text = str(cfg.get_value("menu", "room", room_edit.text))
		ai_count = clampi(int(cfg.get_value("menu", "ai_count", ai_count)), 0, AI_MAX_COUNT)
		ai_level = clampi(int(cfg.get_value("menu", "ai_level", ai_level)), 0, AI_LEVELS.size() - 1)
	ai_count_spin.value = ai_count
	ai_level_option.select(ai_level)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("menu", "name", name_edit.text)
	cfg.set_value("menu", "room", room_edit.text)
	cfg.set_value("menu", "ai_count", ai_count)
	cfg.set_value("menu", "ai_level", ai_level)
	cfg.save(SETTINGS_PATH)


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
	var regex := RegEx.create_from_string("[^a-z0-9_-]")
	var r := regex.sub(room_edit.text.strip_edges().to_lower(), "", true)
	ai_count = int(ai_count_spin.value)
	ai_level = maxi(0, ai_level_option.selected)
	_save_settings()
	_start(nick, r if not r.is_empty() else "lobby")


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
	rt.connect_room(SUPABASE_URL, SUPABASE_KEY, CHANNEL_PREFIX + room, my_id)


func _on_joined() -> void:
	mode = Mode.PLAYING
	menu_root.visible = false
	stats["joined"] = true
	_log("joined room=%s id=%s" % [room, my_id])
	rt.track({"id": my_id, "name": my_name, "color": my_color.to_html(false)})
	_spawn()
	_add_feed("'%s' 방에 입장했습니다" % room)


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
	bullets.clear()
	feed.clear()
	menu_root.visible = true
	join_button.disabled = false
	status_label.text = message


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and mode == Mode.PLAYING:
			_leave()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and rt:
		rt.leave()


# ---------------------------------------------------------------- 매 프레임

func _process(delta: float) -> void:
	elapsed += delta
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
		send_left -= delta
		if send_left <= 0.0:
			send_left = 1.0 / SEND_HZ
			_send_state()
			_send_ai()
	_update_effects(delta)
	queue_redraw()


func _spawn() -> void:
	pos = Vector2(randf_range(80, ARENA.x - 80), randf_range(80, ARENA.y - 80))
	angle = randf_range(-PI, PI)
	speed = 200.0
	hp = bot_hp if bot_mode else MAX_HP
	alive = true
	shield = SHIELD_SEC
	_send_state()


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

	angle = wrapf(angle + turn * TURN_SPEED * delta, -PI, PI)
	speed = clampf(speed + thrust * ACCEL * delta, MIN_SPEED, MAX_SPEED)
	pos = _wrap(pos + Vector2.RIGHT.rotated(angle) * speed * delta)
	if fire and fire_cd <= 0.0:
		_fire()


func _fire() -> void:
	fire_cd = FIRE_COOLDOWN
	bullet_seq += 1
	var bid := "%s-%d" % [my_id, bullet_seq]
	var start := _wrap(pos + Vector2.RIGHT.rotated(angle) * 24.0)
	_add_bullet(bid, my_id, start, angle)
	rt.send_broadcast("shot", {"id": my_id, "bid": bid, "x": start.x, "y": start.y, "a": angle})


func _add_bullet(bid: String, owner: String, start: Vector2, a: float) -> void:
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
	rt.send_broadcast("hit", {"victim": my_id, "shooter": shooter, "bid": bid, "hp": hp, "killed": killed})
	_add_effect(pos, Color(1, 0.9, 0.5), 0.25, 14)
	if killed:
		alive = false
		deaths += 1
		respawn_left = RESPAWN_SEC
		_add_effect(pos, my_color, 0.8, 60)
		_add_feed("%s ▶ %s 격추" % [_name_of(shooter), my_name])
		if ai_planes.has(shooter):
			ai_planes[shooter]["score"] = int(ai_planes[shooter]["score"]) + 1
		_log("shot down by " + _name_of(shooter))
	_send_state()


func _send_state() -> void:
	if not rt:
		return
	rt.send_broadcast("state", {
		"id": my_id, "name": my_name, "color": my_color.to_html(false),
		"x": snappedf(pos.x, 0.1), "y": snappedf(pos.y, 0.1), "a": snappedf(angle, 0.001),
		"v": snappedf(speed, 0.1), "hp": hp, "alive": alive, "score": score, "deaths": deaths,
	})


# ---------------------------------------------------------------- 수신

func _on_broadcast(event: String, p: Dictionary) -> void:
	match event:
		"state":
			var id := str(p.get("id", ""))
			if id != "" and id != my_id:
				stats["states"] += 1
				_upsert_peer(id, p)
		"shot":
			var id := str(p.get("id", ""))
			if id != "" and id != my_id:
				stats["shots"] += 1
				_add_bullet(str(p.get("bid", "")), id, Vector2(float(p.get("x", 0)), float(p.get("y", 0))), float(p.get("a", 0)))
		"hit":
			_on_hit(p)
		"ai":
			_on_ai_states(p)


func _upsert_peer(id: String, p: Dictionary) -> void:
	var target := Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
	var a := float(p.get("a", 0))
	var now_alive := bool(p.get("alive", true))
	var peer: Dictionary
	if peers.has(id):
		peer = peers[id]
		if now_alive and not bool(peer["alive"]):
			peer["pos"] = target
			peer["angle"] = a
	else:
		peer = {"pos": target, "angle": a}
		peers[id] = peer
		stats["peers_seen"] += 1
		_log("peer seen: " + str(p.get("name", id)))
	peer["name"] = str(p.get("name", "?")).left(12)
	peer["color"] = Color.from_string(str(p.get("color", "ffffff")), Color.WHITE)
	peer["target"] = target
	peer["target_angle"] = a
	peer["speed"] = float(p.get("v", 200))
	peer["hp"] = int(p.get("hp", MAX_HP))
	peer["alive"] = now_alive
	peer["score"] = int(p.get("score", 0))
	peer["last_seen"] = elapsed


func _on_hit(p: Dictionary) -> void:
	var victim := str(p.get("victim", ""))
	var shooter := str(p.get("shooter", ""))
	var bid := str(p.get("bid", ""))
	if shooter == my_id:
		stats["hits_given"] = int(stats.get("hits_given", 0)) + 1
	for i in range(bullets.size() - 1, -1, -1):
		if bullets[i]["bid"] == bid:
			bullets.remove_at(i)
	var where := pos
	if peers.has(victim):
		var peer: Dictionary = peers[victim]
		peer["hp"] = int(p.get("hp", 0))
		where = peer["pos"]
		_add_effect(where, Color(1, 0.9, 0.5), 0.25, 14)
	if bool(p.get("killed", false)):
		if peers.has(victim):
			peers[victim]["alive"] = false
			_add_effect(where, peers[victim]["color"], 0.8, 60)
		if shooter == my_id:
			score += 1
			stats["kills"] += 1
			_send_state()
		elif ai_planes.has(shooter):
			ai_planes[shooter]["score"] = int(ai_planes[shooter]["score"]) + 1
		_add_feed("%s ▶ %s 격추" % [_name_of(shooter), _name_of(victim)])


func _on_presence_joined(key: String, meta: Dictionary) -> void:
	if key != my_id:
		_add_feed("%s 입장" % str(meta.get("name", "?")))


func _on_presence_left(key: String, meta: Dictionary) -> void:
	if peers.has(key):
		peers.erase(key)
	# 나간 방장의 AI도 함께 치웁니다. 새 방장이 AI를 다시 띄웁니다.
	for id in peers.keys():
		if peers[id].get("owner", "") == key:
			peers.erase(id)
	if key != my_id:
		_add_feed("%s 퇴장" % str(meta.get("name", "?")))


func _update_peers(delta: float) -> void:
	for id in peers.keys():
		var peer: Dictionary = peers[id]
		if elapsed - float(peer["last_seen"]) > PEER_TIMEOUT:
			peers.erase(id)
			continue
		# 다음 state가 올 때까지 마지막 속도로 예측하고, 화면 위치는 부드럽게 따라갑니다.
		if bool(peer["alive"]):
			peer["target"] = _wrap(peer["target"] + Vector2.RIGHT.rotated(float(peer["target_angle"])) * float(peer["speed"]) * delta)
		var diff := _wrap_delta(peer["pos"], peer["target"])
		if diff.length() > 150.0:
			peer["pos"] = peer["target"]
		else:
			peer["pos"] = _wrap(peer["pos"] + diff * minf(1.0, delta * 10.0))
		peer["angle"] = lerp_angle(float(peer["angle"]), float(peer["target_angle"]), minf(1.0, delta * 12.0))


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
	ai["speed"] = 180.0
	ai["hp"] = MAX_HP
	ai["alive"] = true
	ai["shield"] = SHIELD_SEC
	ai["fire_cd"] = 1.0
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
			thrust = -1.0 if best_d < 220.0 else 0.4
			fire = absf(diff) < float(lv["cone"]) and best_d < 520.0

		# AI끼리 한 덩어리로 뭉치지 않도록 가까운 AI 반대쪽으로 방향을 틉니다.
		var away := Vector2.ZERO
		for other_id in ai_planes:
			if other_id != id and bool(ai_planes[other_id]["alive"]):
				var gap := _wrap_delta(at, ai_planes[other_id]["pos"])
				if gap.length() < 110.0:
					away -= gap.normalized()
		if away != Vector2.ZERO:
			turn = clampf(turn + clampf(wrapf(away.angle() - a, -PI, PI), -1.0, 1.0), -1.0, 1.0)

		a = wrapf(a + turn * float(lv["turn"]) * delta, -PI, PI)
		var v := clampf(float(ai["speed"]) + thrust * ACCEL * delta, MIN_SPEED, float(lv["speed"]))
		ai["angle"] = a
		ai["speed"] = v
		ai["pos"] = _wrap(at + Vector2.RIGHT.rotated(a) * v * delta)

		if fire and float(ai["fire_cd"]) <= 0.0:
			ai["fire_cd"] = float(lv["cooldown"]) + randf() * 0.4
			ai["fire_seq"] = int(ai["fire_seq"]) + 1
			var bid := "%s-%d" % [id, ai["fire_seq"]]
			var start := _wrap(ai["pos"] + Vector2.RIGHT.rotated(a) * 24.0)
			_add_bullet(bid, str(id), start, a)
			rt.send_broadcast("shot", {"id": id, "bid": bid, "x": start.x, "y": start.y, "a": a})


func _ai_take_hit(aid: String, shooter: String, bid: String) -> void:
	var ai: Dictionary = ai_planes[aid]
	ai["hp"] = int(ai["hp"]) - 1
	var killed := int(ai["hp"]) <= 0
	rt.send_broadcast("hit", {"victim": aid, "shooter": shooter, "bid": bid, "hp": ai["hp"], "killed": killed})
	_add_effect(ai["pos"], Color(1, 0.9, 0.5), 0.25, 14)
	if killed:
		ai["alive"] = false
		ai["respawn_left"] = AI_RESPAWN_SEC
		_add_effect(ai["pos"], ai["color"], 0.8, 60)
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
			"v": snappedf(float(ai["speed"]), 0.1), "hp": ai["hp"], "alive": ai["alive"], "score": ai["score"],
		})
	rt.send_broadcast("ai", {"owner": my_id, "level": ai_level, "list": list})


func _on_ai_states(p: Dictionary) -> void:
	var host_id := str(p.get("owner", ""))
	if host_id == "" or host_id == my_id:
		return
	remote_ai_level = int(p.get("level", -1))
	var ids := {}
	var list: Variant = p.get("list", [])
	if typeof(list) == TYPE_ARRAY:
		for s in list:
			if typeof(s) != TYPE_DICTIONARY or str(s.get("id", "")) == "":
				continue
			var id := str(s["id"])
			ids[id] = true
			_upsert_peer(id, s)
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
		return str(rt.presence[id].get("name", "?"))
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
	for peer in peers.values():
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


# ---------------------------------------------------------------- 그리기

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, ARENA), Color(0.05, 0.08, 0.16))
	for x in range(0, int(ARENA.x), 80):
		draw_line(Vector2(x, 0), Vector2(x, ARENA.y), Color(1, 1, 1, 0.03))
	for y in range(0, int(ARENA.y), 80):
		draw_line(Vector2(0, y), Vector2(ARENA.x, y), Color(1, 1, 1, 0.03))
	for s in stars:
		draw_circle(Vector2(s.x, s.y), 0.6 + s.z * 1.2, Color(1, 1, 1, 0.15 + 0.4 * s.z))

	if mode == Mode.PLAYING:
		for b in bullets:
			draw_circle(b["pos"], 3.0, _color_of(str(b["owner"])).lightened(0.4))
		for peer in peers.values():
			if bool(peer["alive"]):
				_draw_plane(peer["pos"], float(peer["angle"]), peer["color"], str(peer["name"]), int(peer["hp"]), false)
		for ai in ai_planes.values():
			if bool(ai["alive"]):
				_draw_plane(ai["pos"], float(ai["angle"]), ai["color"], str(ai["name"]), int(ai["hp"]), float(ai["shield"]) > 0.0)
		if alive:
			_draw_plane(pos, angle, my_color, my_name + " (나)", hp, shield > 0.0)

	for e in effects:
		var k := float(e["t"]) / float(e["dur"])
		var c: Color = e["color"]
		draw_circle(e["pos"], float(e["size"]) * (0.3 + k * 0.7), Color(c.r, c.g, c.b, 0.5 * (1.0 - k)))
		draw_arc(e["pos"], float(e["size"]) * k, 0, TAU, 32, Color(1, 1, 1, 1.0 - k), 2.0)

	if mode == Mode.PLAYING:
		_draw_hud()


func _draw_plane(at: Vector2, a: float, color: Color, label: String, hp_value: int, shielded: bool) -> void:
	var pts := PackedVector2Array()
	for v in PLANE_SHAPE:
		pts.append(at + (v as Vector2).rotated(a))
	var body := color
	if shielded and int(elapsed * 10) % 2 == 0:
		body.a = 0.35
	draw_colored_polygon(pts, body)
	pts.append(pts[0])
	draw_polyline(pts, body.darkened(0.5), 1.5)
	draw_circle(at + Vector2(7, 0).rotated(a), 3.0, Color(0.2, 0.3, 0.5, body.a))
	draw_string(font, at + Vector2(-60, -30), label, HORIZONTAL_ALIGNMENT_CENTER, 120, 14, Color(1, 1, 1, 0.9))
	for i in MAX_HP:
		var c := Color(0.4, 1.0, 0.5) if i < hp_value else Color(1, 1, 1, 0.15)
		draw_rect(Rect2(at + Vector2(-15 + i * 11, 24), Vector2(9, 4)), c)


func _draw_hud() -> void:
	var shown_ai := ai_planes.size()
	for peer in peers.values():
		if bool(peer.get("ai", false)):
			shown_ai += 1
	var level := ai_level if not ai_planes.is_empty() else remote_ai_level
	var ai_text := "AI %d대" % shown_ai
	if shown_ai > 0 and level >= 0 and level < AI_LEVELS.size():
		ai_text += "(%s)" % AI_LEVELS[level]["name"]
	draw_string(font, Vector2(16, 30), "방: %s   접속 %d명   %s   격추 %d   추락 %d" % [room, _humans().size(), ai_text, score, deaths], HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	var y := 58.0
	for f in feed:
		draw_string(font, Vector2(16, y), str(f["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, clampf(float(f["t"]), 0.0, 1.0)))
		y += 22.0

	var board := [{"name": my_name, "score": score, "color": my_color, "me": true}]
	for peer in peers.values():
		board.append({"name": peer["name"], "score": peer["score"], "color": peer["color"], "me": false})
	for ai in ai_planes.values():
		board.append({"name": ai["name"], "score": ai["score"], "color": ai["color"], "me": false})
	board.sort_custom(func(l: Dictionary, r: Dictionary) -> bool: return int(l["score"]) > int(r["score"]))
	draw_rect(Rect2(ARENA.x - 236, 12, 220, 34 + board.size() * 24), Color(0, 0, 0, 0.35))
	draw_string(font, Vector2(ARENA.x - 224, 36), "점수판", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.85, 1.0))
	var row := 62.0
	for entry in board:
		var txt := str(entry["name"]) + (" ★" if entry["me"] else "")
		draw_circle(Vector2(ARENA.x - 216, row - 6), 5, entry["color"])
		draw_string(font, Vector2(ARENA.x - 204, row), txt, HORIZONTAL_ALIGNMENT_LEFT, 140, 16)
		draw_string(font, Vector2(ARENA.x - 64, row), str(entry["score"]), HORIZONTAL_ALIGNMENT_RIGHT, 40, 16)
		row += 24.0

	if not alive:
		draw_string(font, Vector2(0, ARENA.y / 2), "격추되었습니다! %.1f초 뒤 다시 출격" % maxf(respawn_left, 0.0), HORIZONTAL_ALIGNMENT_CENTER, ARENA.x, 28, Color(1, 0.6, 0.5))
	draw_string(font, Vector2(16, ARENA.y - 16), "←→/AD 회전  ↑↓/WS 속도  Space 발사  Esc 나가기", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.5))
