# control_suite.gd
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
extends IVAssistantTestSuite

## Navigation, speed, pause, camera, GUI, action emulation, and body-HUD
## visibility methods for [IVAssistantServer].

var _selection_manager: IVSelectionManager
var _speed_manager: IVSpeedManager
var _timekeeper: IVTimekeeper
var _camera_handler: IVCameraHandler
var _body_huds_state: IVBodyHUDsState


func _on_simulator_started() -> void:
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if top_ui:
		_selection_manager = top_ui.get(&"selection_manager")
	_speed_manager = IVGlobal.program.get(&"SpeedManager")
	_timekeeper = IVGlobal.program.get(&"Timekeeper")
	_camera_handler = IVGlobal.program.get(&"CameraHandler")
	_body_huds_state = IVGlobal.program.get(&"BodyHUDsState")


func _on_about_to_free() -> void:
	_selection_manager = null
	_speed_manager = null
	_timekeeper = null
	_camera_handler = null
	_body_huds_state = null


func get_method_names() -> Array[String]:
	return [
		"select_body", "select_navigate", "set_pause", "set_speed",
		"set_time", "move_camera", "show_hide_gui",
		"list_actions", "press_action",
		"set_all_body_orbits_visibility", "set_body_orbit_visible_flags",
	]


func get_method_requirements() -> Dictionary:
	return {
		"select_body": ["program.TopUI"],
		"select_navigate": ["program.TopUI"],
		"move_camera": ["program.CameraHandler"],
		"set_speed": ["program.SpeedManager"],
		"set_time": ["program.Timekeeper", "core.allow_time_setting"],
		"set_all_body_orbits_visibility": ["program.BodyHUDsState"],
		"set_body_orbit_visible_flags": ["program.BodyHUDsState"],
	}


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
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
		"show_hide_gui":
			return _show_hide_gui(params)
		"list_actions":
			return _list_actions()
		"press_action":
			return _press_action(params)
		"set_all_body_orbits_visibility":
			return _set_all_body_orbits_visibility(params)
		"set_body_orbit_visible_flags":
			return _set_body_orbit_visible_flags(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _select_body(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	_selection_manager.select_by_name(body.name)
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
		var vp_result: Variant = IVAssistantTestSuite.parse_vector3(vp_var, "view_position")
		if vp_result is Dictionary:
			return vp_result
		view_position = vp_result

	# Parse view_rotations (optional)
	var view_rotations := Vector3(-INF, -INF, -INF)
	var vr_var: Variant = params.get("view_rotations")
	if vr_var != null:
		var vr_result: Variant = IVAssistantTestSuite.parse_vector3(vr_var, "view_rotations")
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


func _show_hide_gui(params: Dictionary) -> Dictionary:
	var vis_var: Variant = params.get("visible")
	if typeof(vis_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var vis: bool = vis_var
	IVGlobal.show_hide_gui_requested.emit(false, vis)
	return {"ok": true, "visible": vis}


func _list_actions() -> Dictionary:
	var actions := {}
	for action: StringName in IVInputMapManager.defaults:
		var label: StringName = IVInputMapManager.action_texts.get(action, &"")
		var display_name := tr(label) if label else String(action)
		actions[String(action)] = display_name
	return {"actions": actions}


# Body-HUD visibility (orbits/names/symbols) is persisted via
# [member IVBodyHUDsState.PERSIST_PROPERTIES] and may be restored from a prior
# user session by the project (e.g. planetarium's view cacher). Tests that
# depend on a particular state must set it explicitly and restore on exit.
# Both methods return the previous full [member IVBodyHUDsState.orbit_visible_flags]
# so the caller can pass it to [code]set_body_orbit_visible_flags[/code] later
# to restore exactly.
func _set_all_body_orbits_visibility(params: Dictionary) -> Variant:
	var visible_var: Variant = params.get("visible")
	if typeof(visible_var) != TYPE_BOOL:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'visible' parameter (must be bool)"}}
	var visible: bool = visible_var
	var previous_flags: int = _body_huds_state.orbit_visible_flags
	_body_huds_state.set_all_orbits_visibility(visible)
	return {
		"ok": true,
		"previous_flags": previous_flags,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"all_flags": _body_huds_state.all_flags,
	}


func _set_body_orbit_visible_flags(params: Dictionary) -> Variant:
	var flags_var: Variant = params.get("flags")
	if typeof(flags_var) != TYPE_INT and typeof(flags_var) != TYPE_FLOAT:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'flags' parameter (must be int)"}}
	var flags_num: float = flags_var
	var flags := int(flags_num)
	var previous_flags: int = _body_huds_state.orbit_visible_flags
	_body_huds_state.set_orbit_visible_flags(flags)
	return {
		"ok": true,
		"previous_flags": previous_flags,
		"orbit_visible_flags": _body_huds_state.orbit_visible_flags,
		"all_flags": _body_huds_state.all_flags,
	}


func _press_action(params: Dictionary) -> Dictionary:
	var action_var: Variant = params.get("action")
	if typeof(action_var) != TYPE_STRING or action_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'action' parameter"}}

	var action: String = action_var
	var sn := StringName(action)
	if !InputMap.has_action(sn):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Unknown action: %s" % action}}

	var events := InputMap.action_get_events(sn)
	var key_event: InputEventKey
	for event: InputEvent in events:
		if event is InputEventKey:
			key_event = event
			break

	if !key_event:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Action '%s' has no key binding" % action}}

	var press: InputEventKey = key_event.duplicate()
	press.pressed = true
	Input.parse_input_event(press)

	var release: InputEventKey = key_event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)

	return {"ok": true, "action": action}
