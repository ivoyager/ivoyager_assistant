# Changelog

This file documents changes to [ivoyager_assistant](https://github.com/ivoyager/ivoyager_assistant).

File format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.0.1] - UNRELEASED

Under development using Godot 4.6.1.

### Added
* TCP server (AssistantServer) providing a JSON-RPC-style interface on port 29071 for AI testing and accessibility.
* State queries: `get_state`, `get_time`, `get_selection`, `list_bodies` (with filter for stars, planets, dwarf_planets, moons, spacecraft).
* Basic controls: `select_body`, `set_pause`, `set_speed` (by index, delta, or real_time).
* Application quit: `quit` with optional `force` parameter for clean shutdown.
* AssistantPreinitializer for config-driven registration; server only starts if enabled and (optionally) only in debug builds.
* Configuration via `ivoyager_assistant.cfg` with override support from `ivoyager_override.cfg`.
* Bash helper script `tools/assistant_client.sh` for command-line interaction with the server.
