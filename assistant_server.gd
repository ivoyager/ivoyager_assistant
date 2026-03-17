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

## Singleton [IVAssistantServer] is TCP server providing a JSON-RPC-style
## interface for AI testing and accessibility.
##
## See SPECIFICATION.md for protocol details.

const BodyFlags := IVBody.BodyFlags

# Error codes
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_BODY_NOT_FOUND := 3
const ERR_NOT_STARTED := 4
const ERR_NOT_ALLOWED := 5

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {} # StreamPeerTCP -> PackedByteArray
var _port: int
var _assistant_name: String
var _context_content: String
var _listening := false # TCP server is active
var _sim_started := false # simulator has started, program references cached

var _selection_manager: IVSelectionManager
var _speed_manager: IVSpeedManager
var _timekeeper: IVTimekeeper
var _camera_handler: IVCameraHandler


func _ready() -> void:
	var config := IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	var enabled: bool = config.get_value("assistant", "enabled", true)
	var debug_only: bool = config.get_value("assistant", "debug_only", true)
	if !enabled:
		print("IVAssistantServer: disabled by config")
		set_process(false)
		return
	if debug_only and !OS.is_debug_build():
		print("IVAssistantServer: skipping (not a debug build)")
		set_process(false)
		return
	_port = config.get_value("assistant", "port", 29071)
	_assistant_name = config.get_value("assistant", "assistant_name", "")
	var context_file: String = config.get_value("assistant", "context_file", "")
	if context_file:
		_context_content = _load_context_file(context_file)
	IVStateManager.core_initialized.connect(_on_core_initialized)
	IVStateManager.simulator_started.connect(_on_simulator_started)
	IVStateManager.about_to_quit.connect(_on_about_to_quit)
	IVStateManager.about_to_free_procedural_nodes.connect(_on_about_to_free)


func _on_core_initialized() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err != OK:
		push_error("IVAssistantServer: failed to listen on port %d (error %d)" % [_port, err])
		return
	_listening = true
	print("IVAssistantServer: listening on 127.0.0.1:%d" % _port)


func _on_simulator_started() -> void:
	# Cache references to program objects
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if top_ui:
		_selection_manager = top_ui.get(&"selection_manager")
	_speed_manager = IVGlobal.program.get(&"SpeedManager")
	_timekeeper = IVGlobal.program.get(&"Timekeeper")
	_camera_handler = IVGlobal.program.get(&"CameraHandler")
	_sim_started = true


func _on_about_to_quit() -> void:
	_shutdown()


func _on_about_to_free() -> void:
	_sim_started = false
	_selection_manager = null
	_speed_manager = null
	_timekeeper = null
	_camera_handler = null


func _shutdown() -> void:
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	_buffers.clear()
	_listening = false
	_sim_started = false


func _process(_delta: float) -> void:
	if !_listening:
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
	# Methods available before simulator_started
	match method:
		"get_project_info":
			return _get_project_info()
		"get_state":
			return _get_state()
		"start_game":
			return _start_game()
		"quit":
			return _quit(params)

	# All remaining methods require the simulator to be started
	if !_sim_started:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Simulator not started"}}

	match method:
		# State Queries
		"get_time":
			return _get_time()
		"get_selection":
			return _get_selection()
		"get_camera":
			return _get_camera()
		"list_bodies":
			return _list_bodies(params)
		# Body Queries
		"get_body_info":
			return _get_body_info(params)
		"get_body_position":
			return _get_body_position(params)
		"get_body_orbit":
			return _get_body_orbit(params)
		"get_body_distance":
			return _get_body_distance(params)
		# Controls
		"select_body":
			return _select_body(params)
		"select_navigate":
			return _select_navigate(params)
		"set_pause":
			return _set_pause(params)
		"set_speed":
			return _set_speed(params)
		"set_time":
			return _set_time(params)
		"move_camera":
			return _move_camera(params)
		_:
			return {"_error": {"code": ERR_UNKNOWN_METHOD,
					"message": "Unknown method: %s" % method}}


# ===========================================================================
# Project Info (available before simulator_started)
# ===========================================================================

func _get_project_info() -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var project_version: String = ProjectSettings.get_setting("application/config/version", "")

	# Build capabilities based on available program objects and settings
	var capabilities: Array[String] = [
		"get_state", "get_time", "list_bodies",
		"get_body_info", "get_body_position", "get_body_orbit", "get_body_distance",
		"set_pause", "quit", "get_project_info",
	]
	if IVGlobal.program.has(&"TopUI"):
		capabilities.append("select_body")
		capabilities.append("select_navigate")
		capabilities.append("get_selection")
	if IVGlobal.program.has(&"CameraHandler"):
		capabilities.append("get_camera")
		capabilities.append("move_camera")
	if IVGlobal.program.has(&"SpeedManager"):
		capabilities.append("set_speed")
	if IVGlobal.program.has(&"Timekeeper") and IVCoreSettings.allow_time_setting:
		capabilities.append("set_time")
	if IVCoreSettings.wait_for_start:
		capabilities.append("start_game")

	var display_name := _assistant_name if _assistant_name else project_name

	var result: Dictionary = {
		"project_name": project_name,
		"project_version": project_version,
		"assistant_name": display_name,
		"started": IVStateManager.started,
		"ok_to_start": IVStateManager.ok_to_start,
		"wait_for_start": IVCoreSettings.wait_for_start,
		"allow_time_setting": IVCoreSettings.allow_time_setting,
		"capabilities": capabilities,
	}
	if _context_content:
		result["context"] = _context_content
	return result


func _start_game() -> Dictionary:
	if IVStateManager.started:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Simulator already started"}}
	if !IVStateManager.ok_to_start:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Not ready to start"}}
	IVStateManager.start()
	return {"ok": true}


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


func _get_camera() -> Dictionary:
	if !_camera_handler:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Camera handler not available"}}

	var state: Array = _camera_handler.get_camera_view_state()
	var target_name: String = state[0]
	var camera_flags: int = state[1]
	var view_pos: Vector3 = state[2]
	var view_rot: Vector3 = state[3]

	var is_lock := true
	var camera_3d: Camera3D = get_viewport().get_camera_3d()
	if camera_3d:
		var lock_val: Variant = camera_3d.get(&"is_camera_lock")
		if typeof(lock_val) == TYPE_BOOL:
			var lock_bool: bool = lock_val
			is_lock = lock_bool

	return {
		"target": target_name,
		"flags": camera_flags,
		"view_position": [view_pos.x, view_pos.y, view_pos.z],
		"view_rotations": [view_rot.x, view_rot.y, view_rot.z],
		"is_camera_lock": is_lock,
	}


# ===========================================================================
# Body Queries
# ===========================================================================

func _get_body_info(params: Dictionary) -> Dictionary:
	var body_name: Variant = params.get("name")
	if typeof(body_name) != TYPE_STRING or body_name == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'name' parameter"}}

	var name_str: String = body_name
	var sn := StringName(name_str)
	if !IVBody.bodies.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % name_str}}

	var body: IVBody = IVBody.bodies[sn]

	var parent_name := ""
	if body.parent:
		parent_name = String(body.parent.name)

	var sat_names: Array[String] = []
	for sat_name: StringName in body.satellites:
		sat_names.append(String(sat_name))

	return {
		"name": name_str,
		"gui_name": tr(name_str),
		"flags": body.flags,
		"mean_radius": body.mean_radius,
		"gravitational_parameter": body.gravitational_parameter,
		"parent": parent_name,
		"satellites": sat_names,
	}


func _get_body_position(params: Dictionary) -> Dictionary:
	var body_name: Variant = params.get("name")
	if typeof(body_name) != TYPE_STRING or body_name == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'name' parameter"}}

	var name_str: String = body_name
	var sn := StringName(name_str)
	if !IVBody.bodies.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % name_str}}

	var time_val := NAN
	var time_var: Variant = params.get("time")
	if time_var != null:
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		time_val = time_num

	var body: IVBody = IVBody.bodies[sn]
	var pos: Vector3 = body.get_position_vector(time_val)

	var response_time := time_val
	if is_nan(response_time):
		var current: float = IVGlobal.times[0]
		response_time = current

	return {
		"position": [pos.x, pos.y, pos.z],
		"time": response_time,
	}


func _get_body_orbit(params: Dictionary) -> Dictionary:
	var body_name: Variant = params.get("name")
	if typeof(body_name) != TYPE_STRING or body_name == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'name' parameter"}}

	var name_str: String = body_name
	var sn := StringName(name_str)
	if !IVBody.bodies.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % name_str}}

	var body: IVBody = IVBody.bodies[sn]
	var orbit: IVOrbit = body.get_orbit()
	if !orbit:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Body '%s' has no orbit" % name_str}}

	var time_var: Variant = params.get("time")
	var has_time := time_var != null
	if has_time and typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'time' must be a number"}}

	if has_time:
		var time_num: float = time_var
		return {
			"semi_major_axis": orbit.get_semi_major_axis_at_time(time_num),
			"eccentricity": orbit.get_eccentricity_at_time(time_num),
			"inclination": orbit.get_inclination_at_time(time_num),
			"longitude_ascending_node": orbit.get_longitude_ascending_node_at_time(time_num),
			"argument_periapsis": orbit.get_argument_periapsis_at_time(time_num),
			"period": orbit.get_period_at_time(time_num),
			"time": time_num,
		}
	else:
		var current: float = IVGlobal.times[0]
		return {
			"semi_major_axis": orbit.get_semi_major_axis(),
			"eccentricity": orbit.get_eccentricity(),
			"inclination": orbit.get_inclination(),
			"longitude_ascending_node": orbit.get_longitude_ascending_node(),
			"argument_periapsis": orbit.get_argument_periapsis(),
			"period": orbit.get_period(),
			"time": current,
		}


func _get_body_distance(params: Dictionary) -> Dictionary:
	var name_a: Variant = params.get("body_a")
	if typeof(name_a) != TYPE_STRING or name_a == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'body_a' parameter"}}

	var name_b: Variant = params.get("body_b")
	if typeof(name_b) != TYPE_STRING or name_b == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'body_b' parameter"}}

	var str_a: String = name_a
	var sn_a := StringName(str_a)
	if !IVBody.bodies.has(sn_a):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % str_a}}

	var str_b: String = name_b
	var sn_b := StringName(str_b)
	if !IVBody.bodies.has(sn_b):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Body not found: %s" % str_b}}

	var time_val := NAN
	var time_var: Variant = params.get("time")
	if time_var != null:
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		time_val = time_num

	var body_a: IVBody = IVBody.bodies[sn_a]
	var body_b: IVBody = IVBody.bodies[sn_b]
	var pos_a := _get_global_position(body_a, time_val)
	var pos_b := _get_global_position(body_b, time_val)
	var distance: float = pos_a.distance_to(pos_b)

	var response_time := time_val
	if is_nan(response_time):
		var current: float = IVGlobal.times[0]
		response_time = current

	return {
		"distance": distance,
		"time": response_time,
	}


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


func _select_navigate(params: Dictionary) -> Dictionary:
	if !_selection_manager:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Selection manager not available"}}

	var dir_var: Variant = params.get("direction")
	if typeof(dir_var) != TYPE_STRING or dir_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'direction' parameter"}}

	var direction: String = dir_var
	var can_navigate := false

	match direction:
		"up":
			can_navigate = _selection_manager.has_up()
			if can_navigate:
				_selection_manager.select_up()
		"down":
			can_navigate = _selection_manager.has_down()
			if can_navigate:
				_selection_manager.select_down()
		"next":
			can_navigate = _selection_manager.has_next()
			if can_navigate:
				_selection_manager.select_next()
		"last":
			can_navigate = _selection_manager.has_last()
			if can_navigate:
				_selection_manager.select_last()
		"next_planet":
			can_navigate = _selection_manager.has_next_planet()
			if can_navigate:
				_selection_manager.select_next_planet()
		"last_planet":
			can_navigate = _selection_manager.has_last_planet()
			if can_navigate:
				_selection_manager.select_last_planet()
		"next_moon":
			can_navigate = _selection_manager.has_next_moon()
			if can_navigate:
				_selection_manager.select_next_moon()
		"last_moon":
			can_navigate = _selection_manager.has_last_moon()
			if can_navigate:
				_selection_manager.select_last_moon()
		"next_major_moon":
			can_navigate = _selection_manager.has_next_major_moon()
			if can_navigate:
				_selection_manager.select_next_major_moon()
		"last_major_moon":
			can_navigate = _selection_manager.has_last_major_moon()
			if can_navigate:
				_selection_manager.select_last_major_moon()
		"next_star":
			can_navigate = _selection_manager.has_next_star()
			if can_navigate:
				_selection_manager.select_next_star()
		"last_star":
			can_navigate = _selection_manager.has_last_star()
			if can_navigate:
				_selection_manager.select_last_star()
		"next_spacecraft":
			can_navigate = _selection_manager.has_next_spacecraft()
			if can_navigate:
				_selection_manager.select_next_spacecraft()
		"last_spacecraft":
			can_navigate = _selection_manager.has_last_spacecraft()
			if can_navigate:
				_selection_manager.select_last_spacecraft()
		"history_back":
			can_navigate = _selection_manager.has_history_back()
			if can_navigate:
				_selection_manager.select_history_back()
		"history_forward":
			can_navigate = _selection_manager.has_history_forward()
			if can_navigate:
				_selection_manager.select_history_forward()
		_:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Invalid direction: %s" % direction}}

	if !can_navigate:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Cannot navigate '%s' from current selection" % direction}}

	var sel_name: StringName = _selection_manager.get_name()
	var gui_name: String = _selection_manager.get_gui_name()
	return {"ok": true, "name": String(sel_name), "gui_name": gui_name}


func _set_time(params: Dictionary) -> Dictionary:
	if !_timekeeper:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Timekeeper not available"}}

	if !IVCoreSettings.allow_time_setting:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Time setting is not allowed"}}

	if params.has("time"):
		var time_var: Variant = params["time"]
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		_timekeeper.set_time(time_num)
		return {"ok": true, "time": time_num}

	elif params.has("date"):
		var date_var: Variant = params["date"]
		if typeof(date_var) != TYPE_ARRAY:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'date' must be an array"}}
		var date_arr: Array = date_var
		if date_arr.size() != 3 and date_arr.size() != 6:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'date' must have 3 or 6 elements: [Y,M,D] or [Y,M,D,h,m,s]"}}
		for i in date_arr.size():
			if typeof(date_arr[i]) != TYPE_FLOAT and typeof(date_arr[i]) != TYPE_INT:
				return {"_error": {"code": ERR_INVALID_PARAMS,
						"message": "'date' elements must be integers"}}
		var y_f: float = date_arr[0]
		var m_f: float = date_arr[1]
		var d_f: float = date_arr[2]
		var year := int(y_f)
		var month := int(m_f)
		var day := int(d_f)
		if !IVTimekeeper.is_valid_gregorian_date(year, month, day):
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "Invalid date: %d-%d-%d" % [year, month, day]}}
		if date_arr.size() == 6:
			var h_f: float = date_arr[3]
			var min_f: float = date_arr[4]
			var s_f: float = date_arr[5]
			_timekeeper.set_time_from_date_clock_elements(
					year, month, day, int(h_f), int(min_f), int(s_f))
		else:
			_timekeeper.set_time_from_date_clock_elements(year, month, day)
		var current: float = IVGlobal.times[0]
		return {"ok": true, "time": current}

	elif params.has("os_time"):
		_timekeeper.synchronize_with_operating_system()
		var current: float = IVGlobal.times[0]
		return {"ok": true, "time": current}

	else:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide 'time', 'date', or 'os_time'"}}


func _move_camera(params: Dictionary) -> Dictionary:
	if !_camera_handler:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Camera handler not available"}}

	# Parse target (optional)
	var target_var: Variant = params.get("target")
	var has_target := target_var != null
	var target_sn := StringName()
	if has_target:
		if typeof(target_var) != TYPE_STRING:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'target' must be a string"}}
		var target_str: String = target_var
		target_sn = StringName(target_str)
		if !IVBody.bodies.has(target_sn):
			return {"_error": {"code": ERR_BODY_NOT_FOUND,
					"message": "Body not found: %s" % target_str}}

	# Parse view_position (optional)
	var view_position := Vector3(-INF, -INF, -INF)
	var vp_var: Variant = params.get("view_position")
	if vp_var != null:
		var vp_result: Variant = _parse_vector3(vp_var, "view_position")
		if vp_result is Dictionary:
			return vp_result
		view_position = vp_result

	# Parse view_rotations (optional)
	var view_rotations := Vector3(-INF, -INF, -INF)
	var vr_var: Variant = params.get("view_rotations")
	if vr_var != null:
		var vr_result: Variant = _parse_vector3(vr_var, "view_rotations")
		if vr_result is Dictionary:
			return vr_result
		view_rotations = vr_result

	# Parse instant (optional, default false)
	var instant := false
	var instant_var: Variant = params.get("instant")
	if instant_var != null:
		if typeof(instant_var) != TYPE_BOOL:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'instant' must be a boolean"}}
		var instant_bool: bool = instant_var
		instant = instant_bool

	# Execute camera move
	if has_target:
		_camera_handler.move_to_by_name(target_sn, 0, view_position, view_rotations, instant)
	else:
		_camera_handler.move_to(null, 0, view_position, view_rotations, instant)

	return {"ok": true}


func _quit(params: Dictionary) -> Dictionary:
	var force: bool = params.get("force", false)
	# Send response before quitting - use call_deferred so the response goes out first
	IVStateManager.quit.call_deferred(force)
	return {"ok": true}


# ===========================================================================
# Utilities
# ===========================================================================

func _parse_vector3(value: Variant, param_name: String) -> Variant:
	if typeof(value) != TYPE_ARRAY:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must be an array of 3 numbers" % param_name}}
	var arr: Array = value
	if arr.size() != 3:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'%s' must have exactly 3 elements" % param_name}}
	for i in 3:
		if typeof(arr[i]) != TYPE_FLOAT and typeof(arr[i]) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'%s' elements must be numbers" % param_name}}
	var x: float = arr[0]
	var y: float = arr[1]
	var z: float = arr[2]
	return Vector3(x, y, z)


func _load_context_file(path: String) -> String:
	if !FileAccess.file_exists(path):
		push_warning("IVAssistantServer: context file not found: %s" % path)
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if !file:
		push_warning("IVAssistantServer: failed to open context file: %s" % path)
		return ""
	return file.get_as_text()


func _get_global_position(body: IVBody, time: float) -> Vector3:
	var pos := Vector3.ZERO
	var current: IVBody = body
	while current:
		if current.has_orbit():
			pos += current.get_position_vector(time)
		current = current.parent
	return pos
