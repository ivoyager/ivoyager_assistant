# assistant_server.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2019-2026 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
extends Node

## TCP server providing a JSON-RPC-style interface for AI testing and
## accessibility. See SPECIFICATION.md for protocol details.

const BodyFlags := IVBody.BodyFlags

# Error codes
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_BODY_NOT_FOUND := 3
const ERR_NOT_STARTED := 4
const ERR_NOT_ALLOWED := 5

# Set by AssistantPreinitializer before instantiation
static var configured_port := 29071

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {} # StreamPeerTCP -> PackedByteArray
var _port: int
var _started := false

var _selection_manager: IVSelectionManager
var _speed_manager: IVSpeedManager
var _timekeeper: IVTimekeeper
var _camera_handler: IVCameraHandler


func _ready() -> void:
	_port = configured_port
	IVStateManager.simulator_started.connect(_on_simulator_started)
	IVStateManager.about_to_quit.connect(_on_about_to_quit)
	IVStateManager.about_to_free_procedural_nodes.connect(_on_about_to_free)


func _on_simulator_started() -> void:
	# Cache references to program objects
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if top_ui:
		_selection_manager = top_ui.get(&"selection_manager")
	_speed_manager = IVGlobal.program.get(&"SpeedManager")
	_timekeeper = IVGlobal.program.get(&"Timekeeper")
	_camera_handler = IVGlobal.program.get(&"CameraHandler")

	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err != OK:
		push_error("AssistantServer: failed to listen on port %d (error %d)" % [_port, err])
		return
	_started = true
	print("AssistantServer: listening on 127.0.0.1:%d" % _port)


func _on_about_to_quit() -> void:
	_shutdown()


func _on_about_to_free() -> void:
	_shutdown()


func _shutdown() -> void:
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	_buffers.clear()
	_started = false


func _process(_delta: float) -> void:
	if !_started:
		return

	# Accept new connections
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		if peer:
			_clients.append(peer)
			_buffers[peer] = PackedByteArray()

	# Process each client
	var to_remove: Array[int] = []
	for i in _clients.size():
		var client := _clients[i]
		client.poll()

		var status := client.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
				to_remove.append(i)
			continue

		var available := client.get_available_bytes()
		if available <= 0:
			continue

		var data := client.get_data(available)
		if data[0] != OK:
			continue

		var buf: PackedByteArray = _buffers[client]
		var received: PackedByteArray = data[1]
		buf.append_array(received)
		_buffers[client] = buf

		# Extract complete lines
		_process_buffer(client)

	# Remove disconnected clients (reverse order)
	for i in range(to_remove.size() - 1, -1, -1):
		var client := _clients[to_remove[i]]
		_buffers.erase(client)
		_clients.remove_at(to_remove[i])


func _process_buffer(client: StreamPeerTCP) -> void:
	var buf: PackedByteArray = _buffers[client]
	while true:
		var newline_pos := -1
		for j in buf.size():
			if buf[j] == 10: # '\n'
				newline_pos = j
				break
		if newline_pos == -1:
			break

		var line_bytes := buf.slice(0, newline_pos)
		buf = buf.slice(newline_pos + 1)
		_buffers[client] = buf

		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line.is_empty():
			continue

		var response := _handle_request(line)
		var response_bytes := (response + "\n").to_utf8_buffer()
		client.put_data(response_bytes)


func _handle_request(line: String) -> String:
	var parsed: Variant = JSON.parse_string(line)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return JSON.stringify({"error": {"code": ERR_INVALID_PARAMS, "message": "Invalid JSON"}})

	var request: Dictionary = parsed
	var id: Variant = request.get("id")
	var method: Variant = request.get("method")
	var params: Variant = request.get("params", {})

	if typeof(method) != TYPE_STRING:
		return _error_response(id, ERR_INVALID_PARAMS, "Missing or invalid 'method'")
	if params != null and typeof(params) != TYPE_DICTIONARY:
		return _error_response(id, ERR_INVALID_PARAMS, "'params' must be an object")

	var method_str: String = method
	var p: Dictionary = params if params != null else {}
	var result: Variant = _dispatch(method_str, p)

	if result is Dictionary:
		var result_dict: Dictionary = result
		if result_dict.has("_error"):
			var err_info: Dictionary = result_dict["_error"]
			var err_code: int = err_info["code"]
			var err_msg: String = err_info["message"]
			return _error_response(id, err_code, err_msg)

	var response := {}
	if id != null:
		response["id"] = id
	response["result"] = result
	return JSON.stringify(response)


func _error_response(id: Variant, code: int, message: String) -> String:
	var response := {}
	if id != null:
		response["id"] = id
	response["error"] = {"code": code, "message": message}
	return JSON.stringify(response)


func _dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"get_state":
			return _get_state()
		"get_time":
			return _get_time()
		"get_selection":
			return _get_selection()
		"list_bodies":
			return _list_bodies(params)
		"select_body":
			return _select_body(params)
		"set_pause":
			return _set_pause(params)
		"set_speed":
			return _set_speed(params)
		"quit":
			return _quit(params)
		_:
			return {"_error": {"code": ERR_UNKNOWN_METHOD,
					"message": "Unknown method: %s" % method}}


# ===========================================================================
# State Queries
# ===========================================================================

func _get_state() -> Dictionary:
	var speed_name := ""
	var speed_index := 0
	var reversed := false
	if _speed_manager:
		speed_index = _speed_manager.speed_index
		speed_name = _speed_manager.get_speed_name()
		reversed = _speed_manager.reversed_time

	return {
		"started": IVStateManager.started,
		"running": IVStateManager.running,
		"paused_tree": IVStateManager.paused_tree,
		"paused_by_user": IVStateManager.paused_by_user,
		"building_system": IVStateManager.building_system,
		"time": IVGlobal.times[0],
		"date": [IVGlobal.date[0], IVGlobal.date[1], IVGlobal.date[2]],
		"clock": [IVGlobal.clock[0], IVGlobal.clock[1], IVGlobal.clock[2]],
		"speed_index": speed_index,
		"speed_name": speed_name,
		"reversed_time": reversed,
	}


func _get_time() -> Dictionary:
	var speed_name := ""
	var speed_index := 0
	var reversed := false
	if _speed_manager:
		speed_index = _speed_manager.speed_index
		speed_name = _speed_manager.get_speed_name()
		reversed = _speed_manager.reversed_time

	return {
		"time": IVGlobal.times[0],
		"date": [IVGlobal.date[0], IVGlobal.date[1], IVGlobal.date[2]],
		"clock": [IVGlobal.clock[0], IVGlobal.clock[1], IVGlobal.clock[2]],
		"julian_day_number": IVGlobal.times[3],
		"speed_multiplier": IVGlobal.times[1],
		"speed_index": speed_index,
		"speed_name": speed_name,
		"reversed_time": reversed,
	}


func _get_selection() -> Dictionary:
	if !_selection_manager:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Selection manager not available"}}

	if !_selection_manager.has_selection():
		return {"name": "", "gui_name": "", "is_body": false, "body_flags": 0}

	var sel_name: StringName = _selection_manager.get_name()
	var gui_name: String = _selection_manager.get_gui_name()
	var body: IVBody = _selection_manager.get_body()
	var is_body := body != null
	var body_flags := body.flags if body else 0

	return {
		"name": String(sel_name),
		"gui_name": gui_name,
		"is_body": is_body,
		"body_flags": body_flags,
	}


func _list_bodies(params: Dictionary) -> Dictionary:
	var filter: String = params.get("filter", "all")
	var result: Array[String] = []

	var flag_filter := 0
	match filter:
		"stars":
			flag_filter = BodyFlags.BODYFLAGS_STAR
		"planets":
			flag_filter = BodyFlags.BODYFLAGS_PLANET
		"dwarf_planets":
			flag_filter = BodyFlags.BODYFLAGS_DWARF_PLANET
		"moons":
			flag_filter = BodyFlags.BODYFLAGS_MOON
		"spacecraft":
			flag_filter = BodyFlags.BODYFLAGS_SPACECRAFT
		"all":
			pass
		_:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Invalid filter: %s" % filter}}

	for body_name: StringName in IVBody.bodies:
		if flag_filter == 0:
			result.append(String(body_name))
		else:
			var body: IVBody = IVBody.bodies[body_name]
			if body.flags & flag_filter:
				result.append(String(body_name))

	return {"bodies": result}


# ===========================================================================
# Controls
# ===========================================================================

func _select_body(params: Dictionary) -> Dictionary:
	if !_selection_manager:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Selection manager not available"}}

	var body_name: Variant = params.get("name")
	if typeof(body_name) != TYPE_STRING or body_name == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'name' parameter"}}

	var name_str: String = body_name
	var sn := StringName(name_str)
	if !IVBody.bodies.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % body_name}}

	_selection_manager.select_by_name(sn)
	return {"ok": true}


func _set_pause(params: Dictionary) -> Dictionary:
	var paused_var: Variant = params.get("paused")
	if typeof(paused_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'paused' parameter (must be bool)"}}

	if !IVStateManager.can_user_pause():
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "User pause is not allowed"}}

	var paused: bool = paused_var
	IVStateManager.set_user_paused(paused)
	return {"ok": true}


func _set_speed(params: Dictionary) -> Dictionary:
	if !_speed_manager:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Speed manager not available"}}

	if params.has("real_time"):
		_speed_manager.change_speed(0)
	elif params.has("index"):
		var index: Variant = params["index"]
		if typeof(index) != TYPE_FLOAT and typeof(index) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'index' must be an integer"}}
		var index_num: float = index
		_speed_manager.change_speed(int(index_num))
	elif params.has("delta"):
		var delta: Variant = params["delta"]
		if typeof(delta) != TYPE_FLOAT and typeof(delta) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'delta' must be an integer"}}
		var delta_num: float = delta
		var d := int(delta_num)
		if d > 0:
			for _k in d:
				_speed_manager.increment_speed()
		elif d < 0:
			for _k in -d:
				_speed_manager.decrement_speed()
	else:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide 'index', 'delta', or 'real_time'"}}

	return {
		"ok": true,
		"speed_index": _speed_manager.speed_index,
		"speed_name": String(_speed_manager.get_speed_name()),
	}


func _quit(params: Dictionary) -> Dictionary:
	var force: bool = params.get("force", false)
	# Send response before quitting - use call_deferred so the response goes out first
	IVStateManager.quit.call_deferred(force)
	return {"ok": true}
