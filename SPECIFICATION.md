# I, Voyager Assistant — Specification

## 1. Purpose

The Assistant plugin provides a programmatic interface to the I, Voyager simulation with two goals:

1. **AI-assisted testing** — Enable AI tools (Claude Code) to query simulation state and exercise controls, verifying correctness of orbital mechanics, scene tree construction, time management, and GUI behavior.
2. **Accessibility** — Provide a command-based interface that can be driven by voice control, screen readers, or other assistive technologies for solar system navigation.

## 2. Architecture

### 2.1 Integration with Core

The plugin integrates via the Godot EditorPlugin system:

- **EditorPlugin** — Registers `IVAssistantServer` as an autoload via `add_autoload_singleton()` when the plugin is enabled, and removes it when disabled.
- **IVAssistantServer** — An autoload Node (root-level singleton). Reads config in `_ready()`, starts a TCP server on `core_initialized`, caches program references on `simulator_started`. Processes commands in `_process()` on the main thread.

### 2.2 Component Diagram

```
EditorPlugin (editor/editor_plugin.gd)
  └─ _enter_tree(): reads ivoyager_assistant.cfg, calls add_autoload_singleton()

IVAssistantServer (autoload Node, root-level singleton)
  ├─ _ready(): reads config, checks enabled/debug_only, connects signals
  ├─ on core_initialized: starts TCPServer on localhost:29071 (limited API)
  ├─ on simulator_started: caches program references, enables full API
  └─ _process(): polls TCP, reads JSON commands, dispatches, writes JSON responses
	   ├─ reads from: IVGlobal, IVStateManager, IVCoreSettings, IVBody.bodies,
	   │              SelectionManager, Timekeeper, SpeedManager, CameraHandler
	   └─ writes to: SelectionManager, SpeedManager, Timekeeper, CameraHandler,
					 IVStateManager (pause, start, quit)
```

### 2.3 Lifecycle

1. EditorPlugin registers `IVAssistantServer` as an autoload when the plugin is enabled
2. On game start, `IVAssistantServer._ready()` reads config, checks `enabled`/`debug_only`, connects to `IVStateManager` signals
3. On `core_initialized`: TCP server starts listening, IVSave plugin detected (if present). Only `get_project_info`, `get_state`, `get_save_status`, `start_game`, and `quit` are available
4. On `simulator_started`: program references cached (SelectionManager, SpeedManager, etc.). All API methods become available
5. On `about_to_free_procedural_nodes`: cached references cleared, sim-dependent methods return errors
6. On `about_to_quit`: TCP server shuts down

For projects with `wait_for_start = true` (splash screens), there is a gap between steps 3 and 4 during which the client can connect, query project info, and call `start_game` to bypass the splash screen.

### 2.4 Security

- TCP server binds to `127.0.0.1` only (localhost)
- Server starts only when `OS.is_debug_build()` is true, unless overridden in config
- No authentication (localhost-only, debug-only)

## 3. Communication Protocol

### 3.1 Transport

- **TCP** on `localhost`, default port `29071`
- Port configurable via `ivoyager_assistant.cfg` under `[assistant]` section

### 3.2 Message Format

Newline-delimited JSON. Each message is a single line terminated by `\n`.

**Request:**
```json
{"id": 1, "method": "get_state", "params": {}}
```

**Success response:**
```json
{"id": 1, "result": {...}}
```

**Error response:**
```json
{"id": 1, "error": {"code": 1, "message": "Unknown method"}}
```

- `id` — Integer, echoed back to match request/response pairs. Optional; if omitted, response has no `id`.
- `method` — String, the API method name.
- `params` — Dictionary, method-specific parameters. Optional; defaults to `{}`.

### 3.3 Error Codes

| Code | Meaning |
|------|---------|
| 1 | Unknown method |
| 2 | Invalid parameters |
| 3 | Body not found |
| 4 | Simulator not started |
| 5 | Operation not allowed |
| 6 | Timeout |

## 4. API Methods

### 4.0 Project Info (available before simulator starts)

#### `get_project_info`
Returns project identity, configuration, available capabilities, and optional context. Available as soon as TCP server starts (before `simulator_started`).

**Params:** none

**Result:**
```json
{
  "project_name": "I Voyager Planetarium",
  "project_version": "0.0.20",
  "assistant_name": "I Voyager Planetarium",
  "started": true,
  "ok_to_start": false,
  "wait_for_start": false,
  "allow_time_setting": true,
  "capabilities": ["get_state", "get_time", "list_bodies", "..."]
}
```

- `assistant_name` defaults to `project_name` unless overridden in config.
- `capabilities` lists all methods available based on registered program objects and settings.
- `context` (string, optional) included if a context file is configured.

#### `start_game`
Start the simulation in projects with splash screens (`wait_for_start = true`). Returns error if already started or not ready (assets still loading).

**Params:** none

**Result:** `{"ok": true}`

### 4.1 State Queries

#### `get_state`
Returns overall simulation state. If the Save plugin is present, includes `is_saving` and `is_loading` fields.

**Params:** none

**Result:**
```json
{
  "started": true,
  "running": true,
  "paused_tree": false,
  "paused_by_user": false,
  "building_system": false,
  "time": 7.889e8,
  "date": [2025, 1, 15],
  "clock": [14, 30, 0],
  "speed_index": 0,
  "speed_name": "1x",
  "reversed_time": false,
  "is_saving": false,
  "is_loading": false
}
```

`is_saving` and `is_loading` are only present when the IVSave plugin is enabled.

#### `get_time`
Returns detailed time information.

**Params:** none

**Result:**
```json
{
  "time": 7.889e8,
  "date": [2025, 1, 15],
  "clock": [14, 30, 0],
  "julian_day_number": 2460690,
  "speed_multiplier": 1.0,
  "speed_index": 0,
  "speed_name": "1x",
  "reversed_time": false
}
```

#### `get_selection`
Returns the current GUI selection.

**Params:** none

**Result:**
```json
{
  "name": "PLANET_EARTH",
  "gui_name": "Earth",
  "is_body": true,
  "body_flags": 1048
}
```

#### `get_camera`
Returns camera state.

**Params:** none

**Result:**
```json
{
  "target": "PLANET_EARTH",
  "view_position": [5.0, 0.3, 1.2],
  "view_rotations": [0.0, 0.0, 0.0],
  "is_camera_lock": true
}
```

#### `list_bodies`
Lists celestial bodies in the simulation.

**Params:**
- `filter` (string, optional) — `"all"`, `"stars"`, `"planets"`, `"dwarf_planets"`, `"moons"`, `"spacecraft"`. Default: `"all"`.

**Result:**
```json
{
  "bodies": ["STAR_SUN", "PLANET_MERCURY", "PLANET_VENUS", "PLANET_EARTH", "..."]
}
```

### 4.2 Body Queries

#### `get_body_info`
Returns properties of a celestial body.

**Params:**
- `name` (string, required) — Body name, e.g. `"PLANET_EARTH"`

**Result:**
```json
{
  "name": "PLANET_EARTH",
  "gui_name": "Earth",
  "flags": 1048,
  "mean_radius": 6.371e6,
  "gravitational_parameter": 3.986e14,
  "parent": "STAR_SUN",
  "satellites": ["MOON_MOON", "SPACECRAFT_ISS"]
}
```

#### `get_body_position`
Returns position vector of a body relative to its parent.

**Params:**
- `name` (string, required)
- `time` (float, optional) — TT J2000 seconds. Default: current simulation time.

**Result:**
```json
{
  "position": [1.496e11, 0.0, 0.0],
  "time": 7.889e8
}
```

#### `get_body_orbit`
Returns orbital elements.

**Params:**
- `name` (string, required)
- `time` (float, optional)

**Result:**
```json
{
  "semi_major_axis": 1.496e11,
  "eccentricity": 0.0167,
  "inclination": 0.0,
  "longitude_ascending_node": -0.196,
  "argument_periapsis": 1.796,
  "time": 7.889e8
}
```

#### `get_body_distance`
Returns distance between two bodies.

**Params:**
- `body_a` (string, required)
- `body_b` (string, required)
- `time` (float, optional)

**Result:**
```json
{
  "distance": 3.844e8,
  "time": 7.889e8
}
```

### 4.3 Controls

#### `select_body`
Select a body by name. Moves camera if camera lock is on.

**Params:**
- `name` (string, required)

**Result:** `{"ok": true}`

#### `select_navigate`
Navigate the selection hierarchy.

**Params:**
- `direction` (string, required) — One of: `"up"`, `"down"`, `"next"`, `"last"`, `"next_planet"`, `"last_planet"`, `"next_moon"`, `"last_moon"`, `"next_spacecraft"`, `"last_spacecraft"`, `"next_star"`, `"last_star"`, `"next_major_moon"`, `"last_major_moon"`, `"history_back"`, `"history_forward"`

**Result:** `{"ok": true, "selection": "PLANET_MARS"}`

#### `set_pause`
Pause or resume the simulation.

**Params:**
- `paused` (bool, required)

**Result:** `{"ok": true}`

#### `set_speed`
Change simulation speed.

**Params (one of):**
- `index` (int) — Direct speed index
- `delta` (int) — Increment (+1) or decrement (-1) speed
- `real_time` (bool) — Set to 1x speed if true

**Result:** `{"ok": true, "speed_index": 2, "speed_name": "100x"}`

#### `set_time`
Set simulation time. Requires `IVCoreSettings.allow_time_setting == true`.

**Params (one of):**
- `time` (float) — TT J2000 seconds
- `date` (array) — `[year, month, day]` or `[year, month, day, hour, minute, second]`
- `os_time` (bool) — Sync to operating system time if true

**Result:** `{"ok": true, "time": 7.889e8}`

#### `move_camera`
Move the camera to a target.

**Params:**
- `target` (string, optional) — Body name to move to
- `view_position` (array, optional) — `[r, lat, lon]` spherical coordinates
- `view_rotations` (array, optional) — `[pitch, yaw, roll]`
- `instant` (bool, optional) — Skip animation. Default: false.

**Result:** `{"ok": true}`

### 4.4 GUI Control (Phase 4)

#### `show_hide_gui`
Toggle GUI visibility.

**Params:**
- `visible` (bool, required)

#### `set_option`
Change a user setting.

**Params:**
- `setting` (string, required) — Setting name
- `value` (variant, required) — New value

### 4.5 Save/Load (requires IVSave plugin)

These methods are only available when the `ivoyager_save` plugin is present and enabled. They appear in `get_project_info` capabilities only when detected. If called without the plugin, they return error code 5 ("Save plugin not available").

Save and load operations are **asynchronous**. The methods return `{"ok": true}` immediately. Poll `get_state` to detect completion via the `is_saving` / `is_loading` fields.

#### `save_game`
Trigger a save operation. Requires simulator started.

**Params:**
- `type` (string, optional, default `"quicksave"`) — One of `"quicksave"`, `"named"`, or `"autosave"`
- `path` (string, optional) — File path for `"named"` saves. If omitted for `"named"`, requests a dialog (not useful for automated testing)

**Result:** `{"ok": true}`

**Example:**
```json
{"id": 1, "method": "save_game", "params": {}}
{"id": 1, "method": "save_game", "params": {"type": "quicksave"}}
{"id": 1, "method": "save_game", "params": {"type": "named", "path": "C:/saves/test.MyProjectSave"}}
```

#### `load_game`
Trigger a load operation. Requires simulator started.

**Params:**
- `path` (string, optional) — Specific save file to load. If omitted, loads the most recently modified save file (quickload)

**Result:** `{"ok": true}`

During load, `_sim_started` transitions to `false` and back to `true`. Most other methods return error code 4 during this window. Poll `get_state` (always available) until `started` is `true` and `is_loading` is `false`.

**Example:**
```json
{"id": 1, "method": "load_game", "params": {}}
{"id": 1, "method": "load_game", "params": {"path": "C:/saves/test.MyProjectSave"}}
```

#### `get_save_status`
Query save/load status and file information. Available before simulator starts.

**Params:** none

**Result:**
```json
{
  "is_saving": false,
  "is_loading": false,
  "directory": "C:/Users/user/AppData/Roaming/Godot/app_userdata/ProjectName/saves",
  "has_saves": true,
  "last_modified_path": "C:/Users/.../saves/Quicksave_2026-01-01_12.00.00.MyProjectSave",
  "file_extension": "MyProjectSave"
}
```

### 4.6 Testing Utilities (Phase 3)

#### `screenshot`
Capture viewport to a file.

**Params:**
- `path` (string, required) — Output file path (PNG)

**Result:** `{"ok": true, "path": "/tmp/screenshot.png"}`

## 5. Core API Dependencies

The AssistantServer reads from and writes to these core objects:

| Object | Access Pattern | Used For |
|--------|---------------|----------|
| `IVStateManager` | Autoload singleton | State flags, lifecycle signals, `set_user_paused()` |
| `IVGlobal` | Autoload singleton | `times[]`, `date[]`, `clock[]`, `program{}` |
| `IVBody.bodies` | Static dictionary | Body lookup by name |
| `IVBody` instance | Via bodies dict | Position, velocity, orbit, flags, properties |
| `IVOrbit` | Via `body.get_orbit()` | Orbital elements |
| `SelectionManager` | Via `IVGlobal.program[&"TopUI"].selection_manager` | Selection state and control |
| `SpeedManager` | Via `IVGlobal.program[&"SpeedManager"]` | Speed index, `change_speed()` |
| `Timekeeper` | Via `IVGlobal.program[&"Timekeeper"]` | Time queries and `set_time()` |
| `CameraHandler` | Via `IVGlobal.program[&"CameraHandler"]` | Camera state and `move_to()` |
| `IVSave` | Autoload singleton (optional) | Save/load operations, save status queries (duck-typed) |

## 6. Threading and Safety

- All TCP I/O and command processing runs on the main thread in `_process()`
- This is safe for scene tree access but limits throughput to frame rate (~60 Hz)
- For a testing/accessibility interface, sub-16ms latency is adequate
- The server processes all pending complete messages each frame (not just one)

## 7. Configuration

`ivoyager_assistant.cfg`:

```ini
[assistant_autoload]
IVAssistantServer="../assistant_server.gd"

[assistant]
port=29071
enabled=true
debug_only=true
assistant_name=""
context_file=""
```

### 7.1 Autoload Registration

The `[assistant_autoload]` section declares autoloads managed by the EditorPlugin. When the plugin is enabled in Godot's Plugin manager, `IVAssistantServer` is registered as an autoload. Projects can negate the autoload by setting `IVAssistantServer=""` in `ivoyager_override.cfg`.

### 7.2 Runtime Settings

The `[assistant]` section controls runtime behavior:

- `port` — TCP listen port (default: 29071)
- `enabled` — Master enable/disable (default: true). When false, the autoload node exists but does not start the TCP server.
- `debug_only` — If true, server only starts when `OS.is_debug_build()` is true (default: true)
- `assistant_name` — Display name for the assistant persona (default: empty, uses project name from ProjectSettings)
- `context_file` — Path to a text file (`res://` relative) with project-specific context for AI clients (default: empty)

Base values in `ivoyager_assistant.cfg` can be overridden per-project via `ivoyager_override.cfg` or `ivoyager_override2.cfg`.

## 8. Cross-Project Compatibility

The plugin is designed as a git submodule usable across any I, Voyager project. Enable the plugin in Project Settings → Plugins — no project-level config changes are needed.

### 8.1 Feature Availability

Not all projects support all features. The `capabilities` array returned by `get_project_info` tells the client which methods are available. Capability detection is based on:

- **Program objects**: Methods requiring `TopUI`, `CameraHandler`, `SpeedManager`, or `Timekeeper` are only listed if those objects are registered.
- **Settings**: `set_time` requires `IVCoreSettings.allow_time_setting == true`.
- **Project type**: `start_game` is only listed for projects with `IVCoreSettings.wait_for_start == true`.
- **Plugins**: `save_game`, `load_game`, and `get_save_status` are only listed when the `ivoyager_save` plugin is present.

Methods not in the capabilities list will return appropriate error codes (ERR_NOT_STARTED or ERR_NOT_ALLOWED) if called.

### 8.2 Splash Screen Handling

Projects with `wait_for_start = true` display a splash screen before starting the simulation. The TCP server starts on `core_initialized` (before the splash screen), allowing AI clients to:

1. Connect and call `get_project_info` to discover the project
2. Poll `get_state` to check `started` status
3. Call `start_game` to programmatically start the simulation (bypassing the splash screen)

### 8.3 Project Identity

Projects can customize the assistant's identity via config:
- `assistant_name` — Gives the assistant a project-specific name
- `context_file` — Points to a text file with background information, personality guidelines, or project-specific instructions for AI clients
