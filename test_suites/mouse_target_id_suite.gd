# mouse_target_id_suite.gd
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

## Mouse-driven on-screen-target identification primitives for
## [IVAssistantServer].
##
## Building blocks for staging and verifying the user-visible effect of any
## system that identifies what the mouse is over (today this is
## [code]IVFragmentIdentifier[/code]'s shader-encoded ids on bodies, body
## meshes, and orbit lines, surfaced via [IVMouseTargetLabel]):[br][br]
##
## - [code]warp_mouse[/code] synthesizes an [InputEventMouseMotion] at a
##   given viewport pixel.[br]
## - [code]project_to_screen[/code] converts a body-anchored or raw
##   world-space position into viewport pixel coordinates.[br]
## - [code]get_hover_target[/code] reads the current [IVMouseTargetLabel]
##   text and visibility.[br][br]
##
## [IVSmallBodiesGroup] point projection lives in
## [code]SmallBodiesIdSuite[/code] (see [code]small_bodies_id_suite.gd[/code])
## so projects without small-bodies groups loaded don't carry the dependency.[br][br]
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
	return ["warp_mouse", "project_to_screen", "get_hover_target"]


func get_method_requirements() -> Dictionary:
	return {
		"get_hover_target": ["widget.MouseTargetLabel"],
	}


func get_capabilities() -> Array[String]:
	return ["mouse_target_id"]


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"warp_mouse":
			return _warp_mouse(params)
		"project_to_screen":
			return _project_to_screen(params)
		"get_hover_target":
			return _get_hover_target()
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
	var mode_count := int(has_body) + int(has_world)
	if mode_count != 1:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Provide exactly one of 'body' or 'world_position'"}}

	var world_pos: Vector3

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
	else:
		var pos_or_err: Variant = IVAssistantTestSuite.parse_vector3(
				params.get("world_position"), "world_position")
		if pos_or_err is Dictionary:
			return pos_or_err
		var parsed_pos: Vector3 = pos_or_err
		world_pos = parsed_pos

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
	return {
		"position": [screen.x, screen.y],
		"on_screen": on_screen,
		"behind_camera": behind,
		"world_position_used": [world_pos.x, world_pos.y, world_pos.z],
	}


func _get_hover_target() -> Variant:
	var viewport: Viewport = _server.get_viewport()
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	return {
		"text": _mouse_target_label.text,
		"visible": _mouse_target_label.visible,
		"mouse_position": [mouse_pos.x, mouse_pos.y],
	}
