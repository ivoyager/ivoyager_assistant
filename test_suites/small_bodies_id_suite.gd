# small_bodies_id_suite.gd
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

## Mouse-driven on-screen-target identification primitives for points within
## an [IVSmallBodiesGroup] (today: asteroid points rendered via the SBG
## points shader, identified by [IVFragmentIdentifier]'s sbg-point branch).
##
## Companion to [code]MouseTargetIdSuite[/code]: that suite covers
## body / orbit-line / world-position projection through the scene tree;
## this suite covers the SBG path, which lives in
## [code]IVSmallBodiesGroup[/code]'s static state and uses [IVOrbit]
## Keplerian helpers to reconstruct per-point world positions.[br][br]
##
## Both methods declare [code]runtime.IVSmallBodiesGroup[/code], so they
## drop from the manifest in projects that don't load any
## [IVSmallBodiesGroup] instances (e.g. projects that disable SBG building
## via [member IVTableSystemBuilder.add_small_bodies_groups] = false, or
## omit the [code]small_bodies_groups[/code] table). Re-evaluated on
## [signal IVStateManager.simulator_started].


func get_method_names() -> Array[String]:
	return ["project_small_body_to_screen", "list_small_body_groups"]


func get_method_requirements() -> Dictionary:
	return {
		"project_small_body_to_screen": ["runtime.IVSmallBodiesGroup"],
		"list_small_body_groups": ["runtime.IVSmallBodiesGroup"],
	}


func get_capabilities() -> Array[String]:
	return ["small_bodies_id"]


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"project_small_body_to_screen":
			return _project_small_body_to_screen(params)
		"list_small_body_groups":
			return _list_small_body_groups()
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


func _project_small_body_to_screen(params: Dictionary) -> Variant:
	var sb_or_err: Variant = _world_pos_from_small_body(params)
	if sb_or_err is Dictionary:
		var err_dict: Dictionary = sb_or_err
		if err_dict.has("_error"):
			return err_dict
	var sb_result: Array = sb_or_err
	var world_pos: Vector3 = sb_result[0]
	var sb_name: String = sb_result[1]

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
		"name": sb_name,
		"position": [screen.x, screen.y],
		"on_screen": on_screen,
		"behind_camera": behind,
		"world_position_used": [world_pos.x, world_pos.y, world_pos.z],
	}


# Returns [world_pos: Vector3, name: String] on success or an _error Dictionary.
func _world_pos_from_small_body(params: Dictionary) -> Variant:
	var group_var: Variant = params.get("group")
	if typeof(group_var) != TYPE_STRING or group_var == "":
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'group' must be a non-empty string"}}
	var index_var: Variant = params.get("index")
	if typeof(index_var) != TYPE_INT and typeof(index_var) != TYPE_FLOAT:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'index' must be a number"}}
	var group_name: String = group_var
	var index_num: float = index_var
	var index := int(index_num)
	var sn := StringName(group_name)
	if !IVSmallBodiesGroup.small_bodies_groups.has(sn):
		return {"_error": {"code": ERR_BODY_NOT_FOUND,
				"message": "Small bodies group not found: %s" % group_name}}
	var sbg: IVSmallBodiesGroup = IVSmallBodiesGroup.small_bodies_groups[sn]
	var n_bodies: int = sbg.get_number()
	if index < 0 or index >= n_bodies:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'index' out of range [0, %d)" % n_bodies}}
	if sbg.lp_integer != -1:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Lagrange-point (Trojan) groups are not supported"}}

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
