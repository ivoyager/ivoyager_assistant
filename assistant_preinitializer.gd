# assistant_preinitializer.gd
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
extends RefCounted

## Registers the AssistantServer as a program node if enabled in config.

const AssistantServer := preload("res://addons/ivoyager_assistant/assistant_server.gd")


func _init() -> void:
	var config := _load_config()

	var enabled: bool = config.get_value("assistant", "enabled", true)
	var debug_only: bool = config.get_value("assistant", "debug_only", true)

	if !enabled:
		print("Assistant: disabled by config")
		return
	if debug_only and !OS.is_debug_build():
		print("Assistant: skipping (not a debug build)")
		return

	var port: int = config.get_value("assistant", "port", 29071)
	AssistantServer.configured_port = port

	var assistant_name: String = config.get_value("assistant", "assistant_name", "")
	AssistantServer.configured_assistant_name = assistant_name

	var context_file: String = config.get_value("assistant", "context_file", "")
	AssistantServer.configured_context_file = context_file

	IVCoreInitializer.program_nodes[&"AssistantServer"] = AssistantServer
	print("Assistant: registered AssistantServer (port %d)" % port)


static func _load_config() -> ConfigFile:
	var config := ConfigFile.new()
	config.load("res://addons/ivoyager_assistant/ivoyager_assistant.cfg")
	# Apply project-level overrides
	var override := ConfigFile.new()
	if override.load("res://ivoyager_override.cfg") == OK:
		for section in override.get_sections():
			for key in override.get_section_keys(section):
				config.set_value(section, key, override.get_value(section, key))
	var override2 := ConfigFile.new()
	if override2.load("res://ivoyager_override2.cfg") == OK:
		for section in override2.get_sections():
			for key in override2.get_section_keys(section):
				config.set_value(section, key, override2.get_value(section, key))
	return config
