# Changelog

This file documents changes to [ivoyager_assistant](https://github.com/ivoyager/ivoyager_assistant).

File format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.0.1] - UNRELEASED

Under development using Godot 4.6.1.

### Added
* TCP server (IVAssistantServer autoload) providing a JSON-RPC-style interface on port 29071 for AI testing and accessibility.
* State queries: `get_state`, `get_time`, `get_selection`, `get_camera`, `list_bodies` (with filter for stars, planets, dwarf_planets, moons, spacecraft).
* Body queries: `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance` with optional time parameter.
* Selection navigation: `select_navigate` supporting up, down, next, last, and type-specific traversal (planets, moons, stars, spacecraft, major moons, history).
* Camera control: `move_camera` with optional target, view position, view rotations, and instant move.
* Time control: `set_time` supporting absolute TT seconds, Gregorian date arrays, and OS time sync.
* Basic controls: `select_body`, `set_pause`, `set_speed` (by index, delta, or real_time).
* Application quit: `quit` with optional `force` parameter for clean shutdown.
* EditorPlugin autoload registration: enable the plugin in Project Settings → Plugins and it works — no project-level config changes needed.
* Configuration via `ivoyager_assistant.cfg` with override support from `ivoyager_override.cfg`. Server only starts if enabled and (optionally) only in debug builds.
* Bash helper script `tools/assistant_client.sh` for command-line interaction with the server.
* Cross-project compatibility: two-phase TCP startup (listens on `core_initialized`, full API on `simulator_started`) supporting projects with splash screens.
* Project info: `get_project_info` returns project name, version, assistant name, capabilities, and optional context.
* Game start: `start_game` allows AI clients to bypass splash screens for automated testing.
* Configuration: `assistant_name` and `context_file` config keys for project-specific assistant identity.
* Screenshot capture: `screenshot` method saves viewport to PNG with optional `hide_gui` parameter for clean 3D captures.
* GUI visibility control: `show_hide_gui` method to show/hide all GUI panels (pulled forward from Phase 4 as a screenshot prerequisite).
* State vectors: `get_body_state_vectors` returns position and velocity vectors for orbital mechanics testing.
* Action emulation: `press_action` injects real `InputEventKey` events into Godot's input pipeline, enabling programmatic triggering of any user hotkey action.
* Action listing: `list_actions` returns all registered input actions with display names from `IVInputMapManager`.
* Modular test suite architecture: `IVAssistantTestSuite` RefCounted base class, `[assistant_test_suites]` config section, runtime suite loading with override-config support. Server reduced to TCP infrastructure plus four built-in methods (`get_project_info`, `get_state`, `start_game`, `quit`). Default suites: `StateQuerySuite`, `ControlSuite`, `CoreTestSuite`, `GuiInspectionSuite`.
* Save/load: `save_game` (`quicksave` / `named` / `autosave`), `load_game`, `get_save_status`. Available only when the `ivoyager_save` plugin is present and enabled. Async — poll `get_state`'s `is_saving` / `is_loading` for completion.
* GUI inspection (`GuiInspectionSuite`): `find_nodes` (by class / script class_name / name pattern), `inspect_node` (typed property tree to a configurable depth), `read_node_text` (visible-text harvest in document order; tab-aware, fold-aware). Generic scene-tree introspection that works on any GUI node without per-widget custom code.
* `period` field added to `get_body_orbit` result (in addition to the orbital elements).
* Automated test runner: `tools/assistant_test.py` implements the full generic test sequence (SPECIFICATION.md section 9.3) as a Python script. Capability-aware, skips unsupported features. Supports `--launch`, `--skip-save`, `--host`, `--port` options.
* Readiness gate after `simulator_started`: sim-gated TCP methods now wait `min_ready_delay_frames` consecutive frames (default 10) of `ready_predicate` returning true before becoming available. Default predicate is trivially true, so the default behavior adds only a ~10-frame buffer after `simulator_started`. Projects with deferred main-thread initialization that continues past `simulator_started` (e.g. cross-thread arrival of game-state objects via `call_deferred`) can supply a `ready_predicate: Callable` to gate the server until their state has settled. New `IVAssistantServer.is_ready()` getter exposes the gate state to test suites that opt out of the suite-wide gate (e.g. `CoreTestSuite`); `save_game` and `load_game` now use this getter instead of `IVStateManager.started` directly. Gate re-arms across save/load cycles via the existing `about_to_free_procedural_nodes` reset.
* Mouse-hover identification (`MouseHoverSuite`): `warp_mouse` (synthesizes `InputEventMouseMotion` at a viewport pixel), `project_to_screen` (world-to-pixel via `Camera3D.unproject_position()` for a body, body-orbit point, raw world position, or asteroid in an `IVSmallBodiesGroup`), `get_hover_target` (reads `IVMouseTargetLabel.text` / `visible`), `list_small_body_groups` (enumerates loaded SBGs for asteroid hover staging). Capability `mouse_hover`. Covers all three classes of element identified by `IVFragmentIdentifier` today: body bounding-circle picks (`body`), single-body orbit lines (`body` + `time`), and SBG asteroid points (`small_body`). Reads the user-visible label rather than any specific identifier API, so tests written against this suite remain valid across replacement of the underlying identification mechanism (e.g. a future Compositors-based system replacing `IVFragmentIdentifier`).

### Changed
* Completed doc comments in all files.
* Declarative per-method requirement gating: suites declare prerequisites via `IVAssistantTestSuite.get_method_requirements()` against a closed token vocabulary (`core.*`, `program.*`, `autoload.*`, `body_table.*`, `widget.*`, `runtime.*`) defined in `IVAssistantServer.KNOWN_TOKENS`. Methods whose tokens resolve false are dropped from the dispatch table and listed under `gated_out` in `get_project_info` with the unmet token names. Suites can also opt out wholesale via `is_applicable()`. Built-in suites (`StateQuerySuite`, `ControlSuite`, `CoreTestSuite`, `MouseTargetIdSuite`) now use this path; their hand-rolled `get_capabilities()` filtering and redundant in-dispatch availability checks are removed. Test-suite loading is deferred from `_ready()` to `_on_core_initialized()` so tokens resolve against fully-initialized state. `widget.*` and `runtime.*` tokens re-evaluate on `simulator_started`.
* Manifest v2: `get_project_info` adds `assistant_protocol_version: 2`, a `methods` map (per-method summaries, reserved for future fields), and a `gated_out` array (one entry per registered-but-unavailable method, with unmet tokens). The `capabilities` array remains canonical and is rebuilt from active method names plus suite-supplied feature flags.
* `MouseHoverSuite` renamed to `MouseTargetIdSuite` (file `mouse_target_id_suite.gd`, capability string `mouse_target_id`). The "hover" framing was loose; the suite supplies primitives for mouse-driven on-screen-target identification (warp, project, read).

### Removed
* `MouseTargetIdSuite` (was `MouseHoverSuite`) no longer owns `IVSmallBodiesGroup`-based projection. The `small_body` mode of `project_to_screen` and `list_small_body_groups` are split into the new `SmallBodiesIdSuite` (file `small_bodies_id_suite.gd`, capability string `small_bodies_id`). The new suite gates both methods on `runtime.IVSmallBodiesGroup` (resolved at `simulator_started`), so projects that don't load any `IVSmallBodiesGroup` instances see the methods drop from the manifest. The asteroid projection method is now `project_small_body_to_screen` with flat `group` / `index` parameters (no nested `small_body` object). `tools/assistant_test.py` updated to match.
