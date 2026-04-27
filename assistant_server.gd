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
## API methods are provided by [IVAssistantTestSuite] instances registered via
## the [code][assistant_test_suites][/code] config section. See SPECIFICATION.md
## for protocol and configuration details.

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
var _is_ready := false # readiness gate is open
var _ready_delay_counter := -1 # -1 = predicate not yet true; 0..N = countdown
var _min_ready_delay_frames := 10

## Project-supplied readiness condition. Polled each frame after
## [signal IVStateManager.simulator_started] fires; the readiness gate opens
## after this returns true for [member _min_ready_delay_frames] consecutive
## frames. Default predicate is trivially true (gate opens after the frame
## delay alone). See SPECIFICATION.md §7.4.
var ready_predicate := func() -> bool: return true

# Test suite infrastructure
var _test_suites: Array[IVAssistantTestSuite] = []
var _method_to_suite: Dictionary = {} # String -> IVAssistantTestSuite


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
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
	_min_ready_delay_frames = config.get_value("assistant", "min_ready_delay_frames", 10)
	var context_file: String = config.get_value("assistant", "context_file", "")
	if context_file:
		_context_content = _load_context_file(context_file)
	_load_test_suites(config)
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
	_sim_started = true
	for suite in _test_suites:
		suite._on_simulator_started()


func _on_about_to_quit() -> void:
	_shutdown()


func _on_about_to_free() -> void:
	_sim_started = false
	_is_ready = false
	_ready_delay_counter = -1
	for suite in _test_suites:
		suite._on_about_to_free()


## Whether the readiness gate is open. True after [signal IVStateManager.simulator_started]
## has fired AND [member ready_predicate] has returned true for
## [member _min_ready_delay_frames] consecutive frames. Test suites can call
## this for per-method gating where suite-level [method IVAssistantTestSuite.requires_sim_started]
## is too coarse.
func is_ready() -> bool:
	return _is_ready


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
	_is_ready = false
	_ready_delay_counter = -1


func _process(_delta: float) -> void:
	if !_listening:
		return

	# Evaluate readiness gate. Once flipped, stays flipped until reset by
	# _on_about_to_free or _shutdown.
	if _sim_started and !_is_ready:
		if ready_predicate.call():
			if _ready_delay_counter < 0:
				_ready_delay_counter = 0
			elif _ready_delay_counter >= _min_ready_delay_frames:
				_is_ready = true
			else:
				_ready_delay_counter += 1
		else:
			_ready_delay_counter = -1

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
	# Built-in methods (available before simulator_started)
	match method:
		"get_project_info":
			return _get_project_info()
		"get_state":
			return _get_state()
		"start_game":
			return _start_game()
		"quit":
			return _quit(params)

	# Delegate to test suites
	var suite: IVAssistantTestSuite = _method_to_suite.get(method)
	if suite:
		if suite.requires_sim_started() and !_is_ready:
			return {"_error": {"code": ERR_NOT_STARTED,
					"message": "Simulator not ready"}}
		return suite.dispatch(method, params)

	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


# ===========================================================================
# Built-in methods
# ===========================================================================

func _get_project_info() -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var project_version: String = ProjectSettings.get_setting("application/config/version", "")

	# Built-in capabilities
	var capabilities: Array[String] = ["get_state", "quit", "get_project_info"]
	if IVCoreSettings.wait_for_start:
		capabilities.append("start_game")

	# Gather capabilities from test suites
	for suite in _test_suites:
		capabilities.append_array(suite.get_capabilities())

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


func _get_state() -> Dictionary:
	var result := {
		"started": IVStateManager.started,
		"running": IVStateManager.running,
		"paused_tree": IVStateManager.paused_tree,
		"paused_by_user": IVStateManager.paused_by_user,
		"building_system": IVStateManager.building_system,
		"time": IVGlobal.times[0],
		"date": [IVGlobal.date[0], IVGlobal.date[1], IVGlobal.date[2]],
		"clock": [IVGlobal.clock[0], IVGlobal.clock[1], IVGlobal.clock[2]],
	}
	var speed_manager: IVSpeedManager = IVGlobal.program.get(&"SpeedManager")
	if speed_manager:
		result["speed_index"] = speed_manager.speed_index
		result["speed_name"] = speed_manager.get_speed_name()
		result["reversed_time"] = speed_manager.reversed_time
	else:
		result["speed_index"] = 0
		result["speed_name"] = ""
		result["reversed_time"] = false
	var save_singleton: Node = get_node_or_null(^"/root/IVSave")
	if save_singleton:
		@warning_ignore_start("unsafe_property_access")
		var is_saving: bool = save_singleton.is_saving
		var is_loading: bool = save_singleton.is_loading
		@warning_ignore_restore("unsafe_property_access")
		result["is_saving"] = is_saving
		result["is_loading"] = is_loading
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


func _quit(params: Dictionary) -> Dictionary:
	var force: bool = params.get("force", false)
	# Send response before quitting - use call_deferred so the response goes out first
	IVStateManager.quit.call_deferred(force)
	return {"ok": true}


# ===========================================================================
# Test suite loading
# ===========================================================================

func _load_test_suites(config: ConfigFile) -> void:
	var section := "assistant_test_suites"
	if !config.has_section(section):
		return
	for key in config.get_section_keys(section):
		var path: Variant = config.get_value(section, key)
		if path == null or path == "":
			continue
		var path_str: String = path
		var script: GDScript = load(path_str)
		if !script:
			push_error("IVAssistantServer: failed to load test suite '%s': %s" % [key, path_str])
			continue
		var suite: IVAssistantTestSuite = script.new()
		suite._init_test_suite(self)
		_test_suites.append(suite)
		for method_name in suite.get_method_names():
			if _method_to_suite.has(method_name):
				push_warning("IVAssistantServer: method '%s' registered by multiple test suites; '%s' wins" % [method_name, key])
			_method_to_suite[method_name] = suite
		print("IVAssistantServer: loaded test suite '%s'" % key)


func _load_context_file(path: String) -> String:
	if !FileAccess.file_exists(path):
		push_warning("IVAssistantServer: context file not found: %s" % path)
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if !file:
		push_warning("IVAssistantServer: failed to open context file: %s" % path)
		return ""
	return file.get_as_text()
