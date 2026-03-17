# Changelog

This file documents changes to [ivoyager_assistant](https://github.com/ivoyager/ivoyager_assistant).

File format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.0.1] - UNRELEASED

Under development using Godot 4.6.1.

### Added
* TCP server (AssistantServer) providing a JSON-RPC-style interface on port 29071 for AI testing and accessibility.
* State queries: `get_state`, `get_time`, `get_selection`, `get_camera`, `list_bodies` (with filter for stars, planets, dwarf_planets, moons, spacecraft).
* Body queries: `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance` with optional time parameter.
* Selection navigation: `select_navigate` supporting up, down, next, last, and type-specific traversal (planets, moons, stars, spacecraft, major moons, history).
* Camera control: `move_camera` with optional target, view position, view rotations, and instant move.
* Time control: `set_time` supporting absolute TT seconds, Gregorian date arrays, and OS time sync.
* Basic controls: `select_body`, `set_pause`, `set_speed` (by index, delta, or real_time).
* Application quit: `quit` with optional `force` parameter for clean shutdown.
* AssistantPreinitializer for config-driven registration; server only starts if enabled and (optionally) only in debug builds.
* Configuration via `ivoyager_assistant.cfg` with override support from `ivoyager_override.cfg`.
* Bash helper script `tools/assistant_client.sh` for command-line interaction with the server.
* Cross-project compatibility: two-phase TCP startup (listens on `core_initialized`, full API on `simulator_started`) supporting projects with splash screens.
* Project info: `get_project_info` returns project name, version, assistant name, capabilities, and optional context.
* Game start: `start_game` allows AI clients to bypass splash screens for automated testing.
* Configuration: `assistant_name` and `context_file` config keys for project-specific assistant identity.
