extends Node
## Supabase Realtime 최소 클라이언트.
## Phoenix 채널 프로토콜(vsn 1.0.0)을 WebSocketPeer로 직접 주고받으며 Broadcast와 Presence만 다룹니다.

signal joined
signal failed(reason: String)
signal broadcast_received(event: String, payload: Dictionary)
signal presence_joined(key: String, meta: Dictionary)
signal presence_left(key: String, meta: Dictionary)

const HEARTBEAT_SEC := 25.0
const CONNECT_TIMEOUT := 10.0
const JOIN_TIMEOUT := 10.0

var topic := ""
var presence: Dictionary = {}  # presence 키 -> 최신 meta

var _ws := WebSocketPeer.new()
var _presence_key := ""
var _ref := 0
var _join_ref := ""
var _join_sent := false
var _is_joined := false
var _closing := false
var _heartbeat_left := HEARTBEAT_SEC
var _wait_left := CONNECT_TIMEOUT


func connect_room(base_url: String, api_key: String, room: String, presence_key: String) -> void:
	var url := base_url.replace("https://", "wss://").replace("http://", "ws://")
	url += "/realtime/v1/websocket?apikey=" + api_key.uri_encode() + "&vsn=1.0.0"
	topic = "realtime:" + room
	_presence_key = presence_key
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 20
	var err := _ws.connect_to_url(url)
	if err != OK:
		_fail("웹소켓 연결 실패 (%s)" % error_string(err))


func is_joined() -> bool:
	return _is_joined


func send_broadcast(event: String, payload: Dictionary) -> void:
	if _is_joined:
		_push("broadcast", {"type": "broadcast", "event": event, "payload": payload})


func track(meta: Dictionary) -> void:
	if _is_joined:
		_push("presence", {"type": "presence", "event": "track", "payload": meta})


func leave() -> void:
	if _closing:
		return
	if _is_joined:
		_push("phx_leave", {})
	_closing = true
	_is_joined = false
	_ws.close(1000, "leave")


func _process(delta: float) -> void:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			_wait_left -= delta
			if _wait_left <= 0.0:
				_fail("서버 응답이 없습니다")
		WebSocketPeer.STATE_OPEN:
			if not _join_sent:
				_send_join()
			while _ws.get_available_packet_count() > 0:
				_handle(_ws.get_packet().get_string_from_utf8())
			if not _is_joined and not _closing:
				_wait_left -= delta
				if _wait_left <= 0.0:
					_fail("채널 참가 응답이 없습니다")
			_heartbeat_left -= delta
			if _heartbeat_left <= 0.0:
				_heartbeat_left = HEARTBEAT_SEC
				_ref += 1
				_send("phoenix", "heartbeat", {}, str(_ref), null)
		WebSocketPeer.STATE_CLOSED:
			if not _closing:
				_fail("연결이 끊어졌습니다 (%d %s)" % [_ws.get_close_code(), _ws.get_close_reason()])
			set_process(false)


func _send_join() -> void:
	_join_sent = true
	_wait_left = JOIN_TIMEOUT
	_ref += 1
	_join_ref = str(_ref)
	var payload := {
		"config": {
			"broadcast": {"self": false, "ack": false},
			"presence": {"key": _presence_key, "enabled": true},
			"postgres_changes": [],
			"private": false,
		},
	}
	_send(topic, "phx_join", payload, _join_ref, _join_ref)


func _push(event: String, payload: Dictionary) -> void:
	_ref += 1
	_send(topic, event, payload, str(_ref), _join_ref)


func _send(msg_topic: String, event: String, payload: Dictionary, ref: Variant, join_ref: Variant) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var msg := {"topic": msg_topic, "event": event, "payload": payload, "ref": ref, "join_ref": join_ref}
	_ws.send_text(JSON.stringify(msg))


func _handle(text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY or str(msg.get("topic", "")) != topic:
		return
	var payload: Dictionary = _dict(msg.get("payload"))
	match str(msg.get("event", "")):
		"phx_reply":
			if not _is_joined and str(msg.get("ref", "")) == _join_ref:
				if str(payload.get("status", "")) == "ok":
					_is_joined = true
					joined.emit()
				else:
					_fail("채널 참가 거절: " + JSON.stringify(payload.get("response", {})))
		"broadcast":
			broadcast_received.emit(str(payload.get("event", "")), _dict(payload.get("payload")))
		"presence_state":
			_apply_presence_state(payload)
		"presence_diff":
			_apply_presence_diff(payload)
		"phx_error":
			_fail("채널 오류가 발생했습니다")
		"phx_close":
			if not _closing:
				_fail("서버가 채널을 닫았습니다")
		"system":
			if str(payload.get("status", "")) == "error":
				push_warning("Realtime: " + str(payload.get("message", "")))


func _apply_presence_state(state: Dictionary) -> void:
	for key in presence.keys():
		if not state.has(key):
			var meta: Dictionary = presence[key]
			presence.erase(key)
			presence_left.emit(str(key), meta)
	for key in state.keys():
		var meta := _first_meta(state[key])
		var is_new := not presence.has(key)
		presence[key] = meta
		if is_new:
			presence_joined.emit(str(key), meta)


func _apply_presence_diff(diff: Dictionary) -> void:
	var joins := _dict(diff.get("joins"))
	var leaves := _dict(diff.get("leaves"))
	for key in joins.keys():
		var meta := _first_meta(joins[key])
		var is_new := not presence.has(key)
		presence[key] = meta
		if is_new:
			presence_joined.emit(str(key), meta)
	# 다시 track하면 같은 키가 joins와 leaves에 함께 오므로 joins에 없는 키만 퇴장 처리합니다.
	for key in leaves.keys():
		if not joins.has(key) and presence.has(key):
			var meta: Dictionary = presence[key]
			presence.erase(key)
			presence_left.emit(str(key), meta)


func _first_meta(entry: Variant) -> Dictionary:
	var metas: Variant = _dict(entry).get("metas", [])
	if typeof(metas) == TYPE_ARRAY and not metas.is_empty():
		return _dict(metas[0])
	return {}


func _dict(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}


func _fail(reason: String) -> void:
	if _closing:
		return
	_closing = true
	_is_joined = false
	_ws.close()
	failed.emit(reason)
