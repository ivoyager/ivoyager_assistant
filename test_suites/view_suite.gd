# view_suite.gd
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

## Named-view enumeration and application for [IVAssistantServer].
##
## Binds to the same Core entry point the GUI's default view buttons use:
## [method IVViewManager.set_table_view] (see [IVViewButton]). This is the
## standard "frame the camera" surface — preferred over [code]move_camera[/code]
## (in [code]control_suite.gd[/code]), which reaches below the view layer and
## needs a hand-built perspective-distance vector.

var _view_manager: IVViewManager


func _on_simulator_started() -> void:
	_view_manager = IVGlobal.program.get(&"ViewManager")


func _on_about_to_free() -> void:
	_view_manager = null


func get_method_names() -> Array[String]:
	return ["list_views", "apply_view"]


func get_method_requirements() -> Dictionary:
	return {
		"list_views": ["program.ViewManager"],
		"apply_view": ["program.ViewManager"],
	}


func get_method_summaries() -> Dictionary:
	return {
		"list_views": "List built-in named views with decoded target, tracking, framing, and affected state.",
		"apply_view": "Apply a built-in named view by name (the standard way to frame the camera; e.g. VIEW_ZOOM).",
	}


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"list_views":
			return _list_views()
		"apply_view":
			return _apply_view(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _list_views() -> Dictionary:
	var views := {}
	for view_name: StringName in _view_manager.table_views:
		var view: IVView = _view_manager.table_views[view_name]
		views[String(view_name)] = {
			"scope": "table",
			"target_name": String(view.target_name),
			"tracking": _decode_tracking(view.camera_flags),
			"up_lock": _decode_up_lock(view.camera_flags),
			"view_position": _decode_view_position(view.view_position),
			"affects": _decode_affects(view.flags),
		}
	return {"views": views}


func _apply_view(params: Dictionary) -> Variant:
	var name_var: Variant = params.get("name")
	if typeof(name_var) != TYPE_STRING or name_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'name' parameter"}}
	var name_str: String = name_var
	var view_name := StringName(name_str)
	if !_view_manager.has_table_view(view_name):
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Unknown view: %s (call list_views for valid names)" % name_str}}

	var instant := false
	var instant_var: Variant = params.get("instant")
	if instant_var != null:
		if typeof(instant_var) != TYPE_BOOL:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'instant' must be a boolean"}}
		var instant_bool: bool = instant_var
		instant = instant_bool

	_view_manager.set_table_view(view_name, instant)
	return {"ok": true, "name": String(view_name)}


# =============================================================================
# Decode helpers — IVView carries no description field, so list_views
# synthesizes agent-readable fields from its flag bitmasks.


func _decode_tracking(camera_flags: int) -> String:
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_TRACK_GROUND:
		return "ground"
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_TRACK_ORBIT:
		return "orbit"
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_TRACK_ECLIPTIC:
		return "ecliptic"
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_TRACK_GALACIC:
		return "galactic"
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_TRACK_SUPERGALACIC:
		return "supergalactic"
	return "none"


func _decode_up_lock(camera_flags: int) -> String:
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_UP_LOCKED:
		return "locked"
	if camera_flags & IVCamera.CameraFlags.CAMERAFLAGS_UP_UNLOCKED:
		return "unlocked"
	return "unset"


func _decode_view_position(view_position: Vector3) -> Array:
	# Per component, -INF means "keep current" (e.g. VIEW_ZOOM leaves longitude
	# unset). Map to null — raw -INF is not valid JSON.
	return [
		_nullable_float(view_position.x),
		_nullable_float(view_position.y),
		_nullable_float(view_position.z),
	]


# Returns the float, or null for the -INF "keep current" sentinel.
func _nullable_float(value: float) -> Variant:
	if is_inf(value):
		return null
	return value


func _decode_affects(flags: int) -> Array:
	var affects := []
	if flags & IVView.ViewFlags.VIEWFLAGS_CAMERA_SELECTION:
		affects.append("camera_selection")
	if flags & IVView.ViewFlags.VIEWFLAGS_CAMERA_LONGITUDE:
		affects.append("camera_longitude")
	if flags & IVView.ViewFlags.VIEWFLAGS_CAMERA_ORIENTATION:
		affects.append("camera_orientation")
	if flags & IVView.ViewFlags.VIEWFLAGS_HUDS_VISIBILITY:
		affects.append("huds_visibility")
	if flags & IVView.ViewFlags.VIEWFLAGS_HUDS_COLOR:
		affects.append("huds_color")
	if flags & IVView.ViewFlags.VIEWFLAGS_TIME_STATE:
		affects.append("time_state")
	if flags & IVView.ViewFlags.VIEWFLAGS_SYNC_OS_TIME:
		affects.append("sync_os_time")
	return affects
