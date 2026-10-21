extends Node2D
## Sky Duel 홍보 쇼츠 (1080×1920, 28초). tools/render-promo.ps1이 Movie Maker로 AVI를 만듭니다.
## 실제 게임(main.tscn)을 오프라인 데모 모드로 SubViewport에 띄우고, 그 위에 모션 타이포와 합성 사운드를 얹습니다.

const GameScene := preload("res://main.tscn")

const SIZE := Vector2(1080, 1920)
const DURATION := 28.0
const BPM := 128.0
const DROP := 2.6                       # 훅이 끝나고 게임 화면·비트가 시작되는 시점
const END_CARD := 22.5                  # 엔딩 카드 시작
const PANEL := Rect2(40, 470, 1000, 1170)
const ARENA := Vector2(1280, 720)
const MIX_RATE := 44100

const ORANGE := Color(1.0, 0.58, 0.22)
const CREAM := Color(1.0, 0.9, 0.66)
const CYAN := Color(0.45, 0.9, 1.0)
const NAVY := Color(0.02, 0.05, 0.11)
const WHITE := Color(1, 1, 1)

# 장면별 자막: [시작, 끝, 문구, 크기, 색, 중심 y]
const CAPTIONS := [
	# 훅
	[0.15, 1.5, "하늘을", 200, WHITE, 760.0],
	[0.62, 1.5, "지배하라!", 230, ORANGE, 1010.0],
	[1.6, 2.6, "SKY DUEL", 210, CREAM, 900.0],
	# 장면 2: 설치 없음
	[2.8, 8.0, "브라우저에서", 96, WHITE, 230.0],
	[2.95, 8.0, "바로 출격!", 128, ORANGE, 370.0],
	# 장면 3: 멀티플레이
	[8.0, 13.0, "친구와 함께", 96, WHITE, 230.0],
	[8.15, 13.0, "실시간 공중전", 128, CYAN, 370.0],
	[8.6, 13.0, "같은 방 이름만 입력하면 끝", 54, WHITE, 1765.0],
	# 장면 4: AI 적기
	[13.0, 18.0, "혼자서도 OK", 96, WHITE, 230.0],
	[13.15, 18.0, "AI 적기 최대 8대", 120, ORANGE, 370.0],
	# 장면 5: 연출
	[18.0, 22.5, "입체감 넘치는", 96, WHITE, 230.0],
	[18.15, 22.5, "하늘 위 전투", 128, CYAN, 370.0],
	[18.6, 22.5, "그림자 · 구름 · 기울어지는 기체", 50, WHITE, 1765.0],
	# 엔딩
	[22.6, 99.0, "SKY DUEL", 200, CREAM, 690.0],
	[22.9, 99.0, "실시간 비행기 공중전", 66, WHITE, 870.0],
	[23.7, 99.0, "godottestgame.vercel.app", 58, CYAN, 1265.0],
	[24.0, 99.0, "무료 · 설치 없음 · PC 브라우저", 46, Color(1, 1, 1, 0.85), 1365.0],
	[24.4, 99.0, "Godot 4 · Supabase Realtime", 34, Color(0.7, 0.78, 0.9), 1800.0],
]
const IMPACTS := [0.15, 0.62, 1.6, DROP, 8.0, 13.0, 18.0, END_CARD]  # 흔들림·번쩍임·쿵 소리

var font: Font
var game  # main.gd 인스턴스 (pos, alive, score, ai_count 등을 직접 읽고 씁니다)
var view: SubViewport
var t := 0.0
var cam := ARENA / 2
var shake := 0.0
var flash := 0.0
var last_score := 0
var popups: Array = []      # { pos, t0 }
var streaks: Array = []     # 배경 속도선 Vector3(x, y, 길이)
var impacts_done := {}
var boom_player: AudioStreamPlayer
var rng := RandomNumberGenerator.new()
var noise_seed := 12345


func _ready() -> void:
	rng.seed = 2026
	font = load("res://fonts/NanumGothic-Regular.ttf")
	for i in 40:
		streaks.append(Vector3(rng.randf() * SIZE.x, rng.randf() * SIZE.y, rng.randf_range(80, 260)))

	view = SubViewport.new()
	view.size = Vector2i(PANEL.size)
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	game = GameScene.instantiate()
	view.add_child(game)
	game.start_demo("Ace", 3, 1, 999)

	var music := AudioStreamPlayer.new()
	music.stream = _make_music()
	add_child(music)
	music.play()
	boom_player = AudioStreamPlayer.new()
	boom_player.stream = _make_boom()
	boom_player.volume_db = -3.0
	add_child(boom_player)


func _process(delta: float) -> void:
	t += delta
	if t >= DURATION:
		get_tree().quit()
		return

	# 장면 4에서 AI를 늘리고 난이도를 올려 화면을 북적이게 합니다.
	if t >= 13.0 and game.ai_count < 6:
		game.ai_count = 6
		game.ai_level = 2

	for it in IMPACTS:
		if t >= it and not impacts_done.has(it):
			impacts_done[it] = true
			shake = 22.0 if it < DROP or it == END_CARD else 12.0
			flash = 0.55 if it in [1.6, DROP, END_CARD] else 0.25

	# 내가 격추할 때마다 "격추!" 팝업과 효과음
	if game.score > last_score:
		last_score = game.score
		if t > DROP and t < END_CARD:
			popups.append({"pos": Vector2(rng.randf_range(260, 820), PANEL.position.y + rng.randf_range(160, 320)), "t0": t})
			shake = maxf(shake, 10.0)
			flash = maxf(flash, 0.18)
			boom_player.play()

	shake = maxf(0.0, shake - delta * 60.0)
	flash = maxf(0.0, flash - delta * 3.0)
	for i in streaks.size():
		var s: Vector3 = streaks[i]
		s.y += delta * (900.0 if t < DROP else 380.0)
		s.x -= delta * 120.0
		if s.y > SIZE.y + 300:
			s.y = -300
			s.x = rng.randf() * (SIZE.x + 400)
		streaks[i] = s
	_update_camera(delta)
	queue_redraw()


func _update_camera(delta: float) -> void:
	# 장면 5에서는 더 당겨서 기체 디테일을 보여 줍니다.
	var zoom_mul := 1.0 + 0.45 * _smooth(18.0, 18.6) * (1.0 - _smooth(22.2, 22.7))
	var z := PANEL.size.y / ARENA.y * zoom_mul
	var target: Vector2 = game.pos if game.alive else cam
	if cam.distance_to(target) > 350.0:
		cam = target  # 화면 끝을 넘어 반대편으로 간 경우: 컷
	else:
		cam = cam.lerp(target, minf(1.0, delta * 3.0))
	var half := PANEL.size / (2.0 * z)
	var c := cam
	c.x = clampf(c.x, half.x, ARENA.x - half.x) if half.x * 2.0 < ARENA.x else ARENA.x / 2
	c.y = clampf(c.y, half.y, ARENA.y - half.y) if half.y * 2.0 < ARENA.y else ARENA.y / 2
	view.canvas_transform = Transform2D(0.0, Vector2(z, z), 0.0, PANEL.size / 2 - c * z)


# ---------------------------------------------------------------- 그리기

func _draw() -> void:
	var off := Vector2(rng.randf_range(-shake, shake), rng.randf_range(-shake, shake))
	_draw_background()

	if t >= DROP:
		var k := _ease_out_back(clampf((t - DROP) / 0.35, 0.0, 1.0))
		var pulse := 1.0 + 0.012 * _beat_pulse()
		var s := (1.25 - 0.25 * k) * pulse
		var r := Rect2(PANEL.get_center() - PANEL.size * s / 2 + off, PANEL.size * s)
		draw_rect(r.grow(10), Color(0, 0, 0, 0.45))
		draw_texture_rect(view.get_texture(), r, false, Color(1, 1, 1, clampf((t - DROP) * 4.0, 0.0, 1.0)))
		var border := StyleBoxFlat.new()
		border.draw_center = false
		border.set_border_width_all(6)
		border.border_color = Color(ORANGE.r, ORANGE.g, ORANGE.b, 0.9)
		border.set_corner_radius_all(14)
		draw_style_box(border, r.grow(3))
		if t >= END_CARD:
			draw_rect(r.grow(12), Color(NAVY.r, NAVY.g, NAVY.b, 0.82 * _smooth(END_CARD, END_CARD + 0.4)))

	for c in CAPTIONS:
		_draw_caption(c, off)
	if t >= 3.6 and t < 8.0:
		_draw_chips(["설치 X", "무료", "회원가입 X"], 1765.0, 3.6, 8.0, -1, off)
	if t >= 13.6 and t < 18.0:
		_draw_chips(["쉬움", "보통", "어려움"], 1765.0, 13.6, 18.0, int((t - 13.6) / 0.47) % 3, off)
	if t >= 23.3:
		_draw_cta(off)
	_draw_popups(off)

	if flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, SIZE), Color(1, 1, 1, flash))


func _draw_background() -> void:
	draw_polygon(
		PackedVector2Array([Vector2.ZERO, Vector2(SIZE.x, 0), SIZE, Vector2(0, SIZE.y)]),
		PackedColorArray([Color(0.03, 0.09, 0.18), Color(0.05, 0.12, 0.22), NAVY, Color(0.01, 0.02, 0.05)]))
	var glow := 0.06 + 0.04 * _beat_pulse()
	draw_circle(Vector2(900, 300), 420, Color(ORANGE.r, ORANGE.g, ORANGE.b, glow))
	draw_circle(Vector2(150, 1700), 480, Color(CYAN.r, CYAN.g, CYAN.b, glow))
	for s in streaks:
		var a := Vector2(s.x, s.y)
		draw_line(a, a + Vector2(-0.35, 1).normalized() * s.z, Color(1, 1, 1, 0.07 if t >= DROP else 0.16), 3.0)


func _draw_caption(c: Array, off: Vector2) -> void:
	var t0: float = c[0]
	var t1: float = c[1]
	if t < t0 or t >= t1:
		return
	var k := clampf((t - t0) / 0.28, 0.0, 1.0)
	var s := _ease_out_back(k) * (1.0 + 0.015 * (t - t0))
	var alpha := clampf(k * 3.0, 0.0, 1.0)
	var center := Vector2(SIZE.x / 2, c[5])
	var e := clampf((t - (t1 - 0.2)) / 0.2, 0.0, 1.0)  # 퇴장: 왼쪽으로 빠지며 사라짐
	alpha *= 1.0 - e
	center.x -= e * e * 700.0
	_text_fx(c[2], center + off, c[3], c[4], s, -0.04, -0.22, alpha)


func _draw_chips(labels: Array, y: float, t0: float, t1: float, active: int, off: Vector2) -> void:
	var gap := 24.0
	var widths := []
	var total := -gap
	for l in labels:
		var w := font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 50).x + 64.0
		widths.append(w)
		total += w + gap
	var x := (SIZE.x - total) / 2
	for i in labels.size():
		var k := clampf((t - t0 - i * 0.12) / 0.25, 0.0, 1.0)
		var e := clampf((t - (t1 - 0.2)) / 0.2, 0.0, 1.0)
		var s := _ease_out_back(k)
		var a := clampf(k * 3.0, 0.0, 1.0) * (1.0 - e)
		var w: float = widths[i]
		var on := active == -1 or active == i
		var box := StyleBoxFlat.new()
		box.bg_color = Color(ORANGE.r, ORANGE.g, ORANGE.b, a) if on else Color(1, 1, 1, 0.12 * a)
		box.set_corner_radius_all(40)
		box.border_color = Color(1, 1, 1, 0.5 * a)
		box.set_border_width_all(0 if on else 2)
		var center := Vector2(x + w / 2, y) + off
		draw_set_transform(center, 0.0, Vector2(s, s))
		draw_style_box(box, Rect2(-w / 2, -44, w, 88))
		var tw := font.get_string_size(labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 50).x
		var tc := Color(0.12, 0.06, 0.02, a) if on else Color(1, 1, 1, a)
		draw_string(font, Vector2(-tw / 2, 18), labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 50, tc)
		draw_string_outline(font, Vector2(-tw / 2, 18), labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 50, 2, tc)
		draw_set_transform(Vector2.ZERO)
		x += w + gap


func _draw_cta(off: Vector2) -> void:
	var k := _ease_out_back(clampf((t - 23.3) / 0.3, 0.0, 1.0))
	var s := k * (1.0 + 0.04 * _beat_pulse())
	var w := 720.0
	var h := 150.0
	draw_set_transform(Vector2(SIZE.x / 2, 1075) + off, 0.0, Vector2(s, s))
	var box := StyleBoxFlat.new()
	box.bg_color = ORANGE
	box.set_corner_radius_all(75)
	box.shadow_color = Color(ORANGE.r, ORANGE.g, ORANGE.b, 0.5)
	box.shadow_size = 30
	draw_style_box(box, Rect2(-w / 2, -h / 2, w, h))
	var label := "지금 바로 플레이"
	var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 66).x
	draw_string_outline(font, Vector2(-tw / 2, 24), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 66, 4, Color(0.12, 0.05, 0.0))
	draw_string(font, Vector2(-tw / 2, 24), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 66, Color(0.12, 0.05, 0.0))
	draw_set_transform(Vector2.ZERO)


func _draw_popups(off: Vector2) -> void:
	for i in range(popups.size() - 1, -1, -1):
		var p: Dictionary = popups[i]
		var age := t - float(p["t0"])
		if age > 0.8:
			popups.remove_at(i)
			continue
		var s := _ease_out_back(clampf(age / 0.18, 0.0, 1.0)) * (1.0 + age * 0.2)
		var a := 1.0 - clampf((age - 0.55) / 0.25, 0.0, 1.0)
		_text_fx("격추!", p["pos"] + off + Vector2(0, -age * 60.0), 120, ORANGE, s, -0.08, -0.22, a)


func _text_fx(text: String, center: Vector2, size: int, color: Color, s: float, rot: float, skew: float, alpha: float) -> void:
	# 기울이고(skew) 굵게(외곽선) 그린 레퍼런스풍 타이포
	if alpha <= 0.0 or s <= 0.01:
		return
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := Vector2(-w / 2, size * 0.36)
	draw_set_transform_matrix(Transform2D(rot, Vector2(s, s), skew, center))
	draw_string_outline(font, at + Vector2(7, 9), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(6, size / 6), Color(0, 0, 0, 0.55 * alpha))
	var col := Color(color.r, color.g, color.b, color.a * alpha)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(4, size / 14), col)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _beat_pulse() -> float:
	if t < DROP:
		return 0.0
	var beat := 60.0 / BPM
	return exp(-fposmod(t - DROP, beat) / beat * 6.0)


func _smooth(a: float, b: float) -> float:
	return smoothstep(a, b, t)


func _ease_out_back(x: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3) + c1 * pow(x - 1.0, 2)


# ---------------------------------------------------------------- 사운드 (코드로 합성)

func _noise() -> float:
	noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
	return float(noise_seed) / 1073741824.0 - 1.0


func _make_music() -> AudioStreamWAV:
	var n := int(DURATION * MIX_RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var beat := 60.0 / BPM
	var roots := [55.0, 43.65, 49.0, 41.2]  # A - F - G - E (한 마디씩)
	var chords := [[440.0, 523.25, 659.25], [349.23, 440.0, 523.25], [392.0, 493.88, 587.33], [329.63, 392.0, 493.88]]

	for it in IMPACTS:
		_impact(buf, it, it in [1.6, DROP, END_CARD])
	var i := 0
	var tt := DROP
	while tt < 27.0:
		var bar := int(i / 4) % 4
		_kick(buf, tt)
		if i % 2 == 1:
			_snare(buf, tt)
		_hat(buf, tt + beat / 2.0)
		_bass(buf, tt, beat / 2.0, roots[bar])
		_bass(buf, tt + beat / 2.0, beat / 2.0, roots[bar] * 2.0)
		if tt >= 8.0 and tt < END_CARD:
			for j in 4:
				_arp(buf, tt + j * beat / 4.0, chords[bar][(i * 4 + j) % 3] * (2.0 if j == 3 else 1.0))
		i += 1
		tt += beat
	_riser(buf, END_CARD - 1.5, END_CARD)

	# 마지막 1초 페이드 아웃 + 소프트 클리핑
	var data := PackedByteArray()
	data.resize(n * 2)
	for k in n:
		var v := buf[k]
		var tk := float(k) / MIX_RATE
		if tk > DURATION - 1.0:
			v *= DURATION - tk
		data.encode_s16(k * 2, int(tanh(v * 1.1) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav


func _add(buf: PackedFloat32Array, start: float, length: float, f: Callable) -> void:
	var a := int(start * MIX_RATE)
	var b := mini(buf.size(), a + int(length * MIX_RATE))
	for k in range(maxi(a, 0), b):
		buf[k] += f.call(float(k - a) / MIX_RATE)


func _kick(buf: PackedFloat32Array, at: float) -> void:
	var phase := [0.0]
	_add(buf, at, 0.32, func(x: float) -> float:
		phase[0] += TAU * (45.0 + 90.0 * exp(-x * 35.0)) / MIX_RATE
		return sin(phase[0]) * exp(-x * 8.0) * 0.85)


func _snare(buf: PackedFloat32Array, at: float) -> void:
	_add(buf, at, 0.2, func(x: float) -> float:
		return _noise() * exp(-x * 20.0) * 0.32 + sin(TAU * 190.0 * x) * exp(-x * 30.0) * 0.22)


func _hat(buf: PackedFloat32Array, at: float) -> void:
	var prev := [0.0]
	_add(buf, at, 0.05, func(x: float) -> float:
		var nz := _noise()
		var hp: float = nz - prev[0]
		prev[0] = nz
		return hp * exp(-x * 70.0) * 0.09)


func _bass(buf: PackedFloat32Array, at: float, length: float, freq: float) -> void:
	_add(buf, at, length * 0.92, func(x: float) -> float:
		var ph := TAU * freq * x
		var saw := sin(ph) + sin(ph * 2.0) / 2.0 + sin(ph * 3.0) / 3.0 + sin(ph * 4.0) / 4.0
		return saw * minf(1.0, x * 200.0) * exp(-x * 5.0) * 0.16)


func _arp(buf: PackedFloat32Array, at: float, freq: float) -> void:
	_add(buf, at, 0.11, func(x: float) -> float:
		return signf(sin(TAU * freq * x)) * exp(-x * 25.0) * 0.045)


func _impact(buf: PackedFloat32Array, at: float, big: bool) -> void:
	var lp := [0.0]
	var gain := 1.0 if big else 0.6
	_add(buf, at, 1.0 if big else 0.5, func(x: float) -> float:
		lp[0] += (_noise() - lp[0]) * 0.18
		return (sin(TAU * 52.0 * x) * exp(-x * 4.5) * 0.8 + lp[0] * exp(-x * 7.0) * 1.2) * gain)


func _riser(buf: PackedFloat32Array, from: float, to: float) -> void:
	var length := to - from
	var phase := [0.0]
	_add(buf, from, length, func(x: float) -> float:
		var r := x / length
		phase[0] += TAU * (220.0 + 900.0 * r * r) / MIX_RATE
		return _noise() * r * r * 0.18 + sin(phase[0]) * r * 0.08)


func _make_boom() -> AudioStreamWAV:
	var buf := PackedFloat32Array()
	buf.resize(int(0.6 * MIX_RATE))
	_impact(buf, 0.0, false)
	var data := PackedByteArray()
	data.resize(buf.size() * 2)
	for k in buf.size():
		data.encode_s16(k * 2, int(tanh(buf[k]) * 30000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.data = data
	return wav
