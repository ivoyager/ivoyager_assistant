# gui_inspection_suite.gd
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

## Generic GUI inspection methods for [IVAssistantServer].
##
## Provides scene tree discovery and content harvesting that works on any GUI
## node without per-widget custom code. See SPECIFICATION.md section 4.8.

const MAX_FIND_RESULTS := 50
const DEFAULT_INSPECT_DEPTH := 2
const DEFAULT_MAX_LABELS := 200


func get_method_names() -> Array[String]:
	return ["find_nodes", "inspect_node", "read_node_text"]


func get_capabilities() -> Array[String]:
	return ["gui_inspection"]


func requires_sim_started() -> bool:
	return false


func dispatch(method: String, params: Dictionary) -> Variant:
	match method:
		"find_nodes":
			return _find_nodes(params)
		"inspect_node":
			return _inspect_node(params)
		"read_node_text":
			return _read_node_text(params)
	return {"_error": {"code": ERR_UNKNOWN_METHOD,
			"message": "Unknown method: %s" % method}}


# =============================================================================
# All private methods below use duck-typing and Variant-based Dictionary access
# for generic scene tree introspection, producing unavoidable warnings.
@warning_ignore_start("unsafe_cast", "unsafe_property_access", "unsafe_method_access",
		"untyped_declaration", "unsafe_call_argument", "confusable_local_declaration")


func _find_nodes(params: Dictionary) -> Variant:
	var root_path: String = params.get("root", "/root")
	var root_node := _server.get_tree().root.get_node_or_null(root_path)
	if !root_node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Root node not found: %s" % root_path}}

	var class_filter: String = params.get("class", "")
	var script_class: String = params.get("script_class", "")
	var name_pattern: String = params.get("name_pattern", "")

	if class_filter.is_empty() and script_class.is_empty() and name_pattern.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "At least one of 'class', 'script_class', or"
				+ " 'name_pattern' is required"}}

	# owned=false to include procedurally-created nodes
	var candidates: Array[Node]
	if !class_filter.is_empty():
		candidates = root_node.find_children("*", class_filter, true, false)
	elif !name_pattern.is_empty():
		candidates = root_node.find_children(name_pattern, "", true, false)
	else:
		candidates = root_node.find_children("*", "", true, false)

	var results := []
	for node in candidates:
		if results.size() >= MAX_FIND_RESULTS:
			break

		# Filter by script_class if specified
		if !script_class.is_empty():
			var scr := node.get_script() as Script
			if !scr or scr.get_global_name() != script_class:
				continue

		var entry := {
			"path": String(node.get_path()),
			"class": node.get_class(),
			"name": String(node.name),
		}
		var scr := node.get_script() as Script
		if scr and !scr.get_global_name().is_empty():
			entry["script_class"] = String(scr.get_global_name())
		if node is CanvasItem:
			entry["visible"] = node.visible

		results.append(entry)

	return {"nodes": results, "count": results.size()}


func _inspect_node(params: Dictionary) -> Variant:
	var path: String = params.get("path", "")
	if path.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'path' parameter is required"}}

	var node := _server.get_tree().root.get_node_or_null(path)
	if !node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Node not found: %s" % path}}

	var depth: int = params.get("depth", DEFAULT_INSPECT_DEPTH)
	return _build_inspect_tree(node, depth)


func _read_node_text(params: Dictionary) -> Variant:
	var path: String = params.get("path", "")
	if path.is_empty():
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "'path' parameter is required"}}

	var node := _server.get_tree().root.get_node_or_null(path)
	if !node:
		return {"_error": {"code": ERR_INVALID_PARAMS,
				"message": "Node not found: %s" % path}}

	var max_labels: int = params.get("max_labels", DEFAULT_MAX_LABELS)
	var entries := []
	var truncated := _walk_text(node, entries, max_labels)

	return {
		"path": path,
		"entries": entries,
		"count": entries.size(),
		"truncated": truncated,
	}


# =============================================================================
# Helpers


func _build_inspect_tree(node: Node, depth: int) -> Dictionary:
	var result := {
		"name": String(node.name),
		"class": node.get_class(),
	}

	var scr := node.get_script() as Script
	if scr and !scr.get_global_name().is_empty():
		result["script_class"] = String(scr.get_global_name())

	if node is CanvasItem:
		result["visible"] = node.visible

	# Class-specific properties
	if node is Label:
		result["text"] = node.text
	elif node is RichTextLabel:
		result["text"] = node.get_parsed_text()
	elif node is TabContainer:
		result["current_tab"] = node.current_tab
		result["tab_count"] = node.get_tab_count()
		var tab_names := []
		for i in node.get_tab_count():
			tab_names.append(node.get_tab_title(i))
		result["tab_names"] = tab_names
	elif node is LineEdit:
		result["text"] = node.text
	elif node is TextEdit:
		result["text"] = node.text

	# Duck-typed FoldableContainer detection
	var title_val = node.get("title")
	var folded_val = node.get("folded")
	if title_val != null and title_val is String:
		result["title"] = title_val
	if folded_val != null and folded_val is bool:
		result["folded"] = folded_val

	# Children
	if depth > 0 and node.get_child_count() > 0:
		var children := []
		for child in node.get_children():
			children.append(_build_inspect_tree(child, depth - 1))
		result["children"] = children

	return result


func _walk_text(node: Node, entries: Array, max_labels: int) -> bool:
	## Returns true if truncated.
	if entries.size() >= max_labels:
		return true

	# Skip invisible nodes
	if node is CanvasItem and !node.visible:
		return false

	# Emit structural markers
	if node is TabContainer:
		var tab_names := []
		for i in node.get_tab_count():
			tab_names.append(node.get_tab_title(i))
		entries.append({
			"type": "tab_container",
			"name": String(node.name),
			"current_tab": node.current_tab,
			"tab_names": tab_names,
		})
		# Only recurse the active tab
		var current: int = node.current_tab
		if current >= 0 and current < node.get_child_count():
			var active_child := node.get_child(current)
			if _walk_text(active_child, entries, max_labels):
				return true
		return false

	# Duck-typed FoldableContainer
	var title_val = node.get("title")
	var folded_val = node.get("folded")
	if title_val is String and folded_val is bool:
		entries.append({
			"type": "section",
			"title": title_val,
			"folded": folded_val,
		})
		if folded_val:
			return false # Don't recurse folded sections

	# Emit text content
	if node is Label and !node.text.is_empty() and node.text != " ":
		entries.append({
			"type": "label",
			"name": String(node.name),
			"text": node.text,
		})
	elif node is RichTextLabel:
		var parsed: String = node.get_parsed_text()
		if !parsed.is_empty():
			entries.append({
				"type": "rich_text",
				"name": String(node.name),
				"text": parsed,
			})

	# Recurse children
	for child in node.get_children():
		if _walk_text(child, entries, max_labels):
			return true

	return false
