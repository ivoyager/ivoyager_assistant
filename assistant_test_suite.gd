# assistant_test_suite.gd
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
class_name IVAssistantTestSuite
extends RefCounted

## Base class for test suites that extend [IVAssistantServer]'s API.
##
## Subclass this and register via the [code][assistant_test_suites][/code]
## config section. See SPECIFICATION.md for details.

# Error codes (shared with IVAssistantServer)
const ERR_UNKNOWN_METHOD := 1
const ERR_INVALID_PARAMS := 2
const ERR_BODY_NOT_FOUND := 3
const ERR_NOT_STARTED := 4
const ERR_NOT_ALLOWED := 5

var _server: Node # IVAssistantServer (autoload, no class_name)


## Called after instantiation with the server node reference.
func _init_test_suite(server: Node) -> void:
	_server = server


## Called on [code]simulator_started[/code] — cache program references here.
func _on_simulator_started() -> void:
	pass


## Called on [code]about_to_free_procedural_nodes[/code] — clear references.
func _on_about_to_free() -> void:
	pass


## Return method names this suite handles.
func get_method_names() -> Array[String]:
	return []


## Return capability strings for [code]get_project_info[/code].
func get_capabilities() -> Array[String]:
	return []


## Whether this suite's methods require the simulator to be started.
## If true, the server returns ERR_NOT_STARTED automatically when the sim
## is not running. If false, the suite handles the check internally.
func requires_sim_started() -> bool:
	return true


## Handle a method call. Return a result Dictionary or an [code]_error[/code]
## Dictionary.
func dispatch(_method: String, _params: Dictionary) -> Variant:
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Method not implemented"}}


# ===========================================================================
# Static utilities for use by test suites
# ===========================================================================

## Parses a 3-element numeric array from a JSON-RPC param into a [Vector3].
## Returns the [Vector3] on success or an [code]_error[/code] [Dictionary] on
## failure. [param param_name] is used in error messages.
static func parse_vector3(value: Variant, param_name: String) -> Variant:
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


## Returns [param body]'s position summed up the parent chain at [param time]
## (in heliocentric coordinates for solar-system bodies).
static func get_global_position(body: IVBody, time: float) -> Vector3:
	var pos := Vector3.ZERO
	var current: IVBody = body
	while current:
		if current.has_orbit():
			pos += current.get_position_vector(time)
		current = current.parent
	return pos
