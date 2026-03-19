# core_test_suite.gd
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

## Screenshot, save/load methods for [IVAssistantServer].

var _save_singleton: Node # IVSave, if present (duck-typed)


func _init_test_suite(server: Node) -> void:
	super(server)
	_save_singleton = server.get_node_or_null(^"/root/IVSave")


func requires_sim_started() -> bool:
	return false


func get_method_names() -> Array[String]:
	return ["screenshot", "save_game", "load_game", "get_save_status"]


func get_capabilities() -> Array[String]:
	var caps: Array[String] = ["screenshot"]
	if _save_singleton:
		caps.append("save_game")
		caps.append("load_game")
		caps.append("get_save_status")
	return caps


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"screenshot":
			if !IVStateManager.started:
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not started"}}
			return _screenshot(params)
		"save_game":
			if !IVStateManager.started:
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not started"}}
			return _save_game(params)
		"load_game":
			if !IVStateManager.started:
				return {"_error": {"code": ERR_NOT_STARTED,
						"message": "Simulator not started"}}
			return _load_game(params)
		"get_save_status":
			return _get_save_status()
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _screenshot(params: Dictionary) -> Dictionary:
	var path_var: Variant = params.get("path")
	if typeof(path_var) != TYPE_STRING or path_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Missing or invalid 'path' parameter"}}
	var path: String = path_var

	var hide_gui := false
	var hide_var: Variant = params.get("hide_gui")
	if hide_var != null:
		if typeof(hide_var) != TYPE_BOOL:
			return {"_error": {"code": ERR_INVALID_PARAMS,
					"message": "'hide_gui' must be a boolean"}}
		var hide_bool: bool = hide_var
		hide_gui = hide_bool

	if hide_gui:
		IVGlobal.show_hide_gui_requested.emit(false, false)
		RenderingServer.force_draw(true)

	var image := _server.get_viewport().get_texture().get_image()
	var err := image.save_png(path)

	if hide_gui:
		IVGlobal.show_hide_gui_requested.emit(false, true)

	if err != OK:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Failed to save screenshot: %s" % error_string(err)}}
	return {"ok": true, "path": path, "size": [image.get_width(), image.get_height()]}


func _save_game(params: Dictionary) -> Dictionary:
	if !_save_singleton:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Save plugin not available"}}
	var save_type: String = params.get("type", "quicksave")
	if save_type != "quicksave" and save_type != "named" and save_type != "autosave":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Invalid type '%s'. Use 'quicksave', 'named', or 'autosave'" % save_type}}
	@warning_ignore_start("unsafe_method_access")
	match save_type:
		"quicksave":
			_save_singleton.quicksave()
		"named":
			var path: String = params.get("path", "")
			_save_singleton.save_file(0, path) # 0 = NAMED_SAVE
		"autosave":
			_save_singleton.autosave()
	@warning_ignore_restore("unsafe_method_access")
	return {"ok": true}


func _load_game(params: Dictionary) -> Dictionary:
	if !_save_singleton:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Save plugin not available"}}
	var path: String = params.get("path", "")
	@warning_ignore_start("unsafe_method_access")
	if path:
		_save_singleton.load_file(false, path)
	else:
		_save_singleton.quickload()
	@warning_ignore_restore("unsafe_method_access")
	return {"ok": true}


func _get_save_status() -> Dictionary:
	if !_save_singleton:
		return {"_error": {"code": ERR_NOT_ALLOWED,
				"message": "Save plugin not available"}}
	@warning_ignore_start("unsafe_property_access", "unsafe_method_access",
			"unsafe_call_argument")
	var save_dir: String = _save_singleton.get_directory()
	var result := {
		"is_saving": bool(_save_singleton.is_saving),
		"is_loading": bool(_save_singleton.is_loading),
		"directory": save_dir,
		"has_saves": bool(_save_singleton.has_file(save_dir)),
		"last_modified_path": String(_save_singleton.get_last_modified_file_path(save_dir)),
		"file_extension": String(_save_singleton.file_extension),
	}
	@warning_ignore_restore("unsafe_property_access", "unsafe_method_access",
			"unsafe_call_argument")
	return result
