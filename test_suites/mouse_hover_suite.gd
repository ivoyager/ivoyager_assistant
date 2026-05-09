# mouse_hover_suite.gd
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

## Mouse-hover identification testing for [IVAssistantServer].
##
## Provides primitives for verifying the user-visible effect of any system
## that identifies on-screen elements at the mouse position (today this is
## [code]IVFragmentIdentifier[/code]'s shader-encoded ids on asteroid points
## and orbit lines):[br][br]
##
## - [code]warp_mouse[/code] synthesizes an [InputEventMouseMotion] at a
##   given viewport pixel.[br]
## - [code]project_to_screen[/code] converts a body, body-orbit point, raw
##   world-space position, or asteroid in an [IVSmallBodiesGroup] into
##   viewport pixel coordinates.[br]
## - [code]get_hover_target[/code] reads the current [IVMouseTargetLabel]
##   text and visibility.[br]
## - [code]list_small_body_groups[/code] enumerates loaded
##   [IVSmallBodiesGroup]s for asteroid-point hover staging.[br][br]
##
## The suite reads [member IVMouseTargetLabel.text] (the user-visible effect)
## rather than any specific identifier API, so tests written against this
## suite remain valid across replacement of the underlying identification
## mechanism.

var _mouse_target_label: IVMouseTargetLabel


func _on_simulator_started() -> void:
	var top_ui: Node = IVGlobal.program.get(&"TopUI")
	if !top_ui:
		return
	var found: Node = top_ui.find_child("MouseTargetLabel", true, false)
	if found is IVMouseTargetLabel:
		_mouse_target_label = found


func _on_about_to_free() -> void:
	_mouse_target_label = null


func get_method_names() -> Array[String]:
	return [
		"warp_mouse", "project_to_screen", "get_hover_target",
		"list_small_body_groups",
	]


func get_capabilities() -> Array[String]:
	return ["mouse_hover"]


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"warp_mouse":
			return _warp_mouse(params)
		"project_to_screen":
			return _project_to_screen(params)
		"get_hover_target":
			return _get_hover_target()
		"list_small_body_groups":
			return _list_small_body_groups()
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _warp_mouse(params: Dictionary) -> Variant:
	var pos_var: Variant = params.get("position")
	if typeof(pos_var) != TYPE_ARRAY:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'position' must be an array of 2 numbers"}}
	var pos_arr: Array = pos_var
	if pos_arr.size() != 2:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'position' must have exactly 2 elements"}}
	for i in 2:
		if typeof(pos_arr[i]) != TYPE_FLOAT and typeof(pos_arr[i]) != TYPE_INT:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'position' elements must be numbers"}}
	var x: float = pos_arr[0]
	var y: float = pos_arr[1]
	var screen_pos := Vector2(x, y)
	var motion := InputEventMouseMotion.new()
	motion.position = screen_pos
	motion.global_position = screen_pos
	Input.parse_input_event(motion)
	return {"ok": true, "position": [x, y]}


func _project_to_screen(params: Dictionary) -> Variant:
	var has_body := params.has("body")
	var has_world := params.has("world_position")
	var has_small_body := params.has("small_body")
	var mode_count := int(has_body) + int(has_world) + int(has_small_body)
	if mode_count != 1:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide exactly one of 'body', 'world_position', or 'small_body'"}}

	var world_pos: Vector3
	var extras: Dictionary = {}

	if has_body:
		var body_or_err: Variant = IVAssistantTestSuite.parse_body(params.get("body"), "body")
		if body_or_err is Dictionary:
			return body_or_err
		var body: IVBody = body_or_err
		var time_var: Variant = params.get("time")
		if time_var == null:
			# IVBody extends Node3D — global_position is already in Godot scene-tree
			# world coordinates.
			world_pos = body.global_position
		else:
			if typeof(time_var) != TYPE_FLOAT and typeof(time_var) != TYPE_INT:
				return {"_error": {"code": ERR_INVALID_PARAMS,
						"message": "'time' must be a number"}}
			var time_num: float = time_var
			# Build the body's Godot world position at sim time `time_num`:
			# walk the parent chain summing each ancestor's per-parent local
			# orbit position (already in Godot scene-tree units), then add the
			# topmost body's static global_position to anchor the chain in
			# world space (the universe origin is offset from the Sun via
			# origin-shifting). Useful for landing on the body's orbit line
			# where the body itself isn't.
			var helio := Vector3.ZERO
			var current: IVBody = body
			var root: IVBody = body
			while current:
				root = current
				if current.has_orbit():
					helio += current.get_position_vector(time_num)
				current = current.parent
			world_pos = root.global_position + helio
	elif has_world:
		var pos_or_err: Variant = IVAssistantTestSuite.parse_vector3(
				params.get("world_position"), "world_position")
		if pos_or_err is Dictionary:
			return pos_or_err
		var parsed_pos: Vector3 = pos_or_err
		world_pos = parsed_pos
	else:
		var sb_or_err: Variant = _world_pos_from_small_body(params.get("small_body"))
		if sb_or_err is Dictionary and sb_or_err.has("_error"):
			return sb_or_err
		var sb_result: Array = sb_or_err
		var sb_pos: Vector3 = sb_result[0]
		var sb_name: String = sb_result[1]
		world_pos = sb_pos
		extras["name"] = sb_name

	var viewport: Viewport = _server.get_viewport()
	var camera: Camera3D = viewport.get_camera_3d()
	if !camera:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "No active Camera3D"}}

	var behind: bool = camera.is_position_behind(world_pos)
	var screen: Vector2 = camera.unproject_position(world_pos)
	var rect_size: Vector2 = viewport.get_visible_rect().size
	var on_screen := !behind and (
			screen.x >= 0.0 and screen.y >= 0.0
			and screen.x <= rect_size.x and screen.y <= rect_size.y)
	var response: Dictionary = {
		"position": [screen.x, screen.y],
		"on_screen": on_screen,
		"behind_camera": behind,
		"world_position_used": [world_pos.x, world_pos.y, world_pos.z],
	}
	response.merge(extras)
	return response


# Returns [world_pos: Vector3, name: String] on success or an _error Dictionary.
func _world_pos_from_small_body(sb_var: Variant) -> Variant:
	if typeof(sb_var) != TYPE_DICTIONARY:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'small_body' must be an object with 'group' and 'index'"}}
	var sb: Dictionary = sb_var
	var group_var: Variant = sb.get("group")
	if typeof(group_var) != TYPE_STRING or group_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'small_body.group' must be a non-empty string"}}
	var index_var: Variant = sb.get("index")
	if typeof(index_var) != TYPE_INT and typeof(index_var) != TYPE_FLOAT:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'small_body.index' must be a number"}}
	var group_name: String = group_var
	var index: int = int(index_var)
	var sn := StringName(group_name)
	if !IVSmallBodiesGroup.small_bodies_groups.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Small bodies group not found: %s" % group_name}}
	var sbg: IVSmallBodiesGroup = IVSmallBodiesGroup.small_bodies_groups[sn]
	var n_bodies: int = sbg.get_number()
	if index < 0 or index >= n_bodies:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'small_body.index' out of range [0, %d)" % n_bodies}}
	if sbg.lp_integer != -1:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Lagrange-point (Trojan) groups are not supported by project_to_screen"}}

	# Reconstruct the asteroid's local position (relative to its primary body)
	# from stored orbital elements. The SBG stores `a` and the resulting
	# Kepler-derived position in Godot scene-tree units (the points shader
	# reads the same arrays to render vertex positions in world space), so no
	# unit scaling is needed. Anchor in world coords by adding the primary's
	# global_position. Precession (s, g rates from sbg.s_g_mag_de) is ignored
	# — for main-belt asteroids the per-decade drift is well within the
	# fragment identifier's ~9-pixel sample radius.
	var elements: Array[float] = sbg.get_orbit_elements(index)
	var a: float = elements[0]
	var e: float = elements[1]
	var inc: float = elements[2]
	var lan: float = elements[3]
	var ap: float = elements[4]
	var m0: float = elements[5]
	var n: float = elements[6]
	var current_time: float = IVGlobal.times[0]
	var mean_anomaly: float = m0 + n * current_time
	var true_anomaly: float = IVOrbit.get_true_anomaly_from_mean_anomaly_elliptic(
			e, mean_anomaly)
	var semi_parameter: float = a * (1.0 - e * e)
	var local_pos: Vector3 = IVOrbit.get_position_from_elements_at_true_anomaly(
			semi_parameter, e, inc, lan, ap, true_anomaly)
	var primary: Node3D = sbg.get_parent()
	if !primary:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "Small bodies group has no primary parent"}}
	var world_pos: Vector3 = primary.global_position + local_pos
	var sb_name: String = sbg.names[index]
	return [world_pos, sb_name]


func _get_hover_target() -> Variant:
	if !_mouse_target_label:
		return {"_error": {"code": ERR_NOT_STARTED,
				"message": "MouseTargetLabel not found"}}
	var viewport: Viewport = _server.get_viewport()
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	return {
		"text": _mouse_target_label.text,
		"visible": _mouse_target_label.visible,
		"mouse_position": [mouse_pos.x, mouse_pos.y],
	}


func _list_small_body_groups() -> Dictionary:
	var groups: Array[Dictionary] = []
	for sbg_name: StringName in IVSmallBodiesGroup.small_bodies_groups:
		var sbg: IVSmallBodiesGroup = IVSmallBodiesGroup.small_bodies_groups[sbg_name]
		groups.append({
			"name": String(sbg_name),
			"alias": String(sbg.sbg_alias),
			"count": sbg.get_number(),
			"lp_integer": sbg.lp_integer,
		})
	return {"groups": groups}
