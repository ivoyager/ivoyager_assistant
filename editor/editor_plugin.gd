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

# This file registers autoloads for the assistant plugin. If you modify
# autoloads in ivoyager_assistant.cfg or ivoyager_override.cfg, you'll need to
# disable and re-enable the plugin for changes to take effect.

const REQUIRED_PLUGINS: Array[String] = ["ivoyager_core"]

var _config: ConfigFile # with overrides
var _autoloads: Dictionary[String, String] = {}



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
	_add_autoloads()


func _exit_tree() -> void:
	print("Removing I, Voyager - Assistant (plugin)")
	_remove_autoloads()
	_config = null


func _is_required_plugins_enabled() -> bool:
	for plugin in REQUIRED_PLUGINS:
		if !EditorInterface.is_plugin_enabled(plugin):
			return false
	return true


func _add_autoloads() -> void:
	for autoload_name in _config.get_section_keys("assistant_autoload"):
		var value: Variant = _config.get_value("assistant_autoload", autoload_name)
		if value: # could be null or "" to negate
			assert(typeof(value) == TYPE_STRING,
					"'%s' must specify a path as String" % autoload_name)
			_autoloads[autoload_name] = value
	for autoload_name in _autoloads:
		var path := _autoloads[autoload_name]
		add_autoload_singleton(autoload_name, path)


func _remove_autoloads() -> void:
	for autoload_name: String in _autoloads:
		remove_autoload_singleton(autoload_name)
	_autoloads.clear()
