# state_query_suite.gd
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

## State and body query methods for [IVAssistantServer].

const BodyFlags := IVBody.BodyFlags

var _selection_manager: IVSelectionManager
var _speed_manager: IVSpeedManager
var _timekeeper: IVTimekeeper
var _camera_handler: IVCameraHandler


func _on_simulator_started() -> void:
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if top_ui:
		_selection_manager = top_ui.get(&"selection_manager")
	_speed_manager = IVGlobal.program.get(&"SpeedManager")
	_timekeeper = IVGlobal.program.get(&"Timekeeper")
	_camera_handler = IVGlobal.program.get(&"CameraHandler")


func _on_about_to_free() -> void:
	_selection_manager = null
	_speed_manager = null
	_timekeeper = null
	_camera_handler = null


func get_method_names() -> Array[String]:
	return [
		"get_time", "get_selection", "get_camera", "list_bodies",
		"get_body_info", "get_body_position", "get_body_orbit",
		"get_body_distance", "get_body_state_vectors",
	]


func get_capabilities() -> Array[String]:
	var caps: Array[String] = [
		"get_time", "list_bodies",
		"get_body_info", "get_body_position", "get_body_orbit",
		"get_body_distance", "get_body_state_vectors",
	]
	if IVGlobal.program.has(&"TopUI"):
		caps.append("get_selection")
	if IVGlobal.program.has(&"CameraHandler"):
		caps.append("get_camera")
	return caps


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"get_time":
			return _get_time()
		"get_selection":
			return _get_selection()
		"get_camera":
			return _get_camera()
		"list_bodies":
			return _list_bodies(params)
		"get_body_info":
			return _get_body_info(params)
		"get_body_position":
			return _get_body_position(params)
		"get_body_orbit":
			return _get_body_orbit(params)
		"get_body_distance":
			return _get_body_distance(params)
		"get_body_state_vectors":
			return _get_body_state_vectors(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


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
	var camera_3d: Camera3D = _server.get_viewport().get_camera_3d()
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


func _get_body_info(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	var parent_name := ""
	if body.parent:
		parent_name = String(body.parent.name)

	var sat_names: Array[String] = []
	for sat_name: StringName in body.satellites:
		sat_names.append(String(sat_name))

	var name_str := String(body.name)
	return {
		"name": name_str,
		"gui_name": tr(name_str),
		"flags": body.flags,
		"mean_radius": body.mean_radius,
		"gravitational_parameter": body.gravitational_parameter,
		"parent": parent_name,
		"satellites": sat_names,
	}


func _get_body_position(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	var time_val := NAN
	var time_var: Variant = params.get("time")
	if time_var != null:
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		time_val = time_num

	var pos: Vector3 = body.get_position_vector(time_val)

	var response_time := time_val
	if is_nan(response_time):
		var current: float = IVGlobal.times[0]
		response_time = current

	return {
		"position": [pos.x, pos.y, pos.z],
		"time": response_time,
	}


func _get_body_orbit(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	var orbit: IVOrbit = body.get_orbit()
	if !orbit:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Body '%s' has no orbit" % String(body.name)}}

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


func _get_body_distance(params: Dictionary) -> Variant:
	var body_a_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("body_a"), "body_a")
	if body_a_or_err is Dictionary:
		return body_a_or_err
	var body_a: IVBody = body_a_or_err

	var body_b_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("body_b"), "body_b")
	if body_b_or_err is Dictionary:
		return body_b_or_err
	var body_b: IVBody = body_b_or_err

	var time_val := NAN
	var time_var: Variant = params.get("time")
	if time_var != null:
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		time_val = time_num

	var pos_a := IVAssistantTestSuite.get_global_position(body_a, time_val)
	var pos_b := IVAssistantTestSuite.get_global_position(body_b, time_val)
	var distance: float = pos_a.distance_to(pos_b)

	var response_time := time_val
	if is_nan(response_time):
		var current: float = IVGlobal.times[0]
		response_time = current

	return {
		"distance": distance,
		"time": response_time,
	}


func _get_body_state_vectors(params: Dictionary) -> Variant:
	var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("name"), "name")
	if body_or_err is Dictionary:
		return body_or_err
	var body: IVBody = body_or_err

	var time_val := NAN
	var time_var: Variant = params.get("time")
	if time_var != null:
		if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'time' must be a number"}}
		var time_num: float = time_var
		time_val = time_num

	var vectors: Array[Vector3] = body.get_state_vectors(time_val)
	var pos: Vector3 = vectors[0]
	var vel: Vector3 = vectors[1]

	var response_time := time_val
	if is_nan(response_time):
		var current: float = IVGlobal.times[0]
		response_time = current

	return {
		"position": [pos.x, pos.y, pos.z],
		"velocity": [vel.x, vel.y, vel.z],
		"time": response_time,
	}
