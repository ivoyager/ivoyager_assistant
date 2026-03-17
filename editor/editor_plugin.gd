# editor_plugin.gd
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
@tool
extends EditorPlugin

# This file delays plugin init until ivoyager_core plugin is enabled.

const REQUIRED_PLUGINS: Array[String] = ["ivoyager_core"]

var _config: ConfigFile # with overrides



func _enter_tree() -> void:
	
	# Wait for required plugins...
	await get_tree().process_frame
	var wait_counter := 0
	while !_is_required_plugins_enabled():
		wait_counter += 1
		if wait_counter == 10:
			push_error("Enable required plugins before ivoyager_assistant: " + str(REQUIRED_PLUGINS))
			push_error("After enabling plugins above, you MUST disable & re-enable ivoyager_assistant!")
			return
		await get_tree().process_frame
	
	IVAssistantPluginUtils.print_plugin_name_and_version(
			"ivoyager_assistant", " - https://ivoyager.dev")
	_config = IVAssistantPluginUtils.get_ivoyager_config(
			"res://addons/ivoyager_assistant/ivoyager_assistant.cfg")


func _exit_tree() -> void:
	print("Removing I, Voyager - Assistant (plugin)")
	_config = null


func _is_required_plugins_enabled() -> bool:
	for plugin in REQUIRED_PLUGINS:
		if !EditorInterface.is_plugin_enabled(plugin):
			return false
	return true
