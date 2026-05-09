# I, Voyager Assistant — Specification

## 1. Purpose

The Assistant plugin provides a programmatic interface to the I, Voyager simulation with two goals:

1. **AI-assisted testing** — Enable AI tools (Claude Code) to query simulation state and exercise controls, verifying correctness of orbital mechanics, scene tree construction, time management, and GUI behavior.
2. **Accessibility** — Provide a command-based interface that can be driven by voice control, screen readers, or other assistive technologies for solar system navigation.

## 2. Architecture

### 2.1 Integration with Core

The plugin integrates via the Godot EditorPlugin system:

- **EditorPlugin** — Registers `IVAssistantServer` as an autoload via `add_autoload_singleton()` when the plugin is enabled, and removes it when disabled.
- **IVAssistantServer** — An autoload Node (root-level singleton). Reads config in `_ready()`, loads test suites, starts a TCP server on `core_initialized`, forwards lifecycle events to suites on `simulator_started`. Processes commands in `_process()` on the main thread.
- **IVAssistantTestSuite** — RefCounted base class for test suites. Each suite registers method names and handles dispatch. Suites are loaded from the `[assistant_test_suites]` config section and can be added, replaced, or removed via override config files.

### 2.2 Component Diagram

```
EditorPlugin (editor/editor_plugin.gd)
  └─ _enter_tree(): reads ivoyager_assistant.cfg, calls add_autoload_singleton()

IVAssistantServer (autoload Node, root-level singleton)
  ├─ _ready(): reads config, loads test suites, checks enabled/debug_only, connects signals
  ├─ on core_initialized: starts TCPServer on localhost:29071
  ├─ on simulator_started: forwards to all test suites
  └─ _process(): polls TCP, reads JSON commands, dispatches, writes JSON responses
	   ├─ built-in: get_project_info, get_state, start_game, quit
	   └─ delegates to test suites for all other methods

IVAssistantTestSuite (RefCounted base class)
  ├─ StateQuerySuite: get_time, get_selection, get_camera, list_bodies, body queries
  ├─ ControlSuite: select_body, select_navigate, set_pause, set_speed, set_time,
  │                move_camera, show_hide_gui, list_actions, press_action
  ├─ CoreTestSuite: screenshot, save_game, load_game, get_save_status
  ├─ GuiInspectionSuite: find_nodes, inspect_node, read_node_text
  └─ MouseHoverSuite: warp_mouse, project_to_screen, get_hover_target,
					  list_small_body_groups
```

### 2.3 Lifecycle

1. EditorPlugin registers `IVAssistantServer` as an autoload when the plugin is enabled
2. On game start, `IVAssistantServer._ready()` reads config, checks `enabled`/`debug_only`, loads test suites from `[assistant_test_suites]` config section, connects to `IVStateManager` signals
3. On `core_initialized`: TCP server starts listening. Only built-in methods (`get_project_info`, `get_state`, `start_game`, `quit`) and test suite methods that don't require sim started (e.g. `get_save_status`) are available
4. On `simulator_started`: forwarded to all test suites so they can cache program references. The readiness gate begins evaluating each frame.
5. **Readiness gate opens** after the project-supplied `ready_predicate` (default trivially true) has returned `true` for `min_ready_delay_frames` consecutive frames (default 10). Sim-gated API methods become available only at this point. See §7.3 and §7.4.
6. On `about_to_free_procedural_nodes`: forwarded to all test suites to clear references, sim-dependent methods return errors. The readiness gate re-arms (closes until the next `simulator_started` plus delay).
7. On `about_to_quit`: TCP server shuts down

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
| 4 | Simulator not ready (not started, or readiness gate not yet open) |
| 5 | Operation not allowed |

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

#### `quit`
Shut down the application.

**Params:**
- `force` (bool, optional, default `false`) — If `true`, quit immediately without confirmation dialog. If `false`, may trigger a "Quit without saving?" dialog in projects that use one.

**Result:** `{"ok": true}`

Note: Response is sent before quit executes (via `call_deferred`).

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
  "period": 3.156e7,
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

#### `get_body_state_vectors`
Returns position and velocity vectors of a body relative to its parent.

**Params:**
- `name` (string, required)
- `time` (float, optional) — TT J2000 seconds. Default: current simulation time.

**Result:**
```json
{
  "position": [1.496e11, 0.0, 0.0],
  "velocity": [0.0, 2.978e4, 0.0],
  "time": 7.889e8
}
```

Note: Velocity computation is experimental (`@experimental` in IVOrbit).

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

### 4.4 GUI Control

#### `show_hide_gui`
Show or hide all GUI panels. Emits `IVGlobal.show_hide_gui_requested` which is handled by `IVShowHideUI`.

**Params:**
- `visible` (bool, required) — true to show, false to hide

**Result:** `{"ok": true, "visible": true}`

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

During load, the readiness gate closes (on `about_to_free_procedural_nodes`) and re-opens after the next `simulator_started` plus `min_ready_delay_frames` frames of the project's `ready_predicate` returning `true` (see §7.3, §7.4). Sim-gated methods (including `save_game` and `load_game`) return error code 4 during this window. Poll `get_state` (always available) until `started` is `true` and `is_loading` is `false`, then allow a brief settling period before re-issuing sim-gated calls — or simply retry on error code 4.

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

### 4.6 Testing Utilities

#### `screenshot`
Capture viewport to a PNG file. Optionally hides GUI before capture and restores it after.

**Params:**
- `path` (string, required) — Output file path (must be a valid writable path)
- `hide_gui` (bool, optional, default false) — Temporarily hide GUI, force a synchronous render, capture, then restore GUI

**Result:**
```json
{
  "ok": true,
  "path": "C:/tmp/screenshot.png",
  "size": [1920, 1080]
}
```

When `hide_gui` is true, the method hides the GUI via `IVGlobal.show_hide_gui_requested`, calls `RenderingServer.force_draw(true)` to synchronously render a frame without GUI, captures, then restores GUI visibility. Alternatively, call `show_hide_gui` separately before `screenshot` — the per-frame TCP processing naturally inserts a render between requests.

### 4.7 Action Emulation

#### `list_actions`
Returns all registered input actions with their display names. Actions are defined by `IVInputMapManager` and include display toggles, camera controls, selection navigation, time controls, and administrative actions.

**Params:** none

**Result:**
```json
{
  "actions": {
	"toggle_orbits": "Show/Hide Orbits",
	"toggle_names": "Show/Hide Names",
	"toggle_symbols": "Show/Hide Symbols",
	"toggle_pause": "Toggle Pause",
	"recenter": "Recenter",
    "..."
  }
}
```

#### `press_action`
Emulates a user hotkey press. Injects a real `InputEventKey` into Godot's input pipeline via `Input.parse_input_event()`, so it flows through `_shortcut_input()` handlers exactly like a physical key press. Both press and release events are injected.

**Params:**
- `action` (string, required) — Action name from `list_actions` (e.g. `"toggle_orbits"`)

**Result:** `{"ok": true, "action": "toggle_orbits"}`

Note: Camera movement actions (e.g. `camera_up`) are designed for sustained key holds. An instant press+release has negligible effect — use `move_camera` for camera positioning instead.

### 4.8 GUI Inspection

Generic scene tree inspection methods that work on any GUI node without per-widget custom code. Available before simulator starts. Capability: `gui_inspection`.

#### `find_nodes`
Discover nodes by class, script class_name, or name pattern.

**Params (at least one required):**
- `class` (string, optional) — Godot built-in class name (e.g., `"TabContainer"`)
- `script_class` (string, optional) — GDScript `class_name` (e.g., `"MyCustomPanel"`)
- `name_pattern` (string, optional) — Glob match on node name (e.g., `"*Panel*"`)
- `root` (string, optional) — Node path to search from (default: `"/root"`)

**Result (example):**
```json
{
  "nodes": [
    {"path": "/root/Universe/TopUI/.../MyPanel", "class": "MarginContainer", "script_class": "MyCustomPanel", "name": "MyPanel", "visible": true}
  ],
  "count": 1
}
```

Capped at 50 results.

#### `inspect_node`
Return a node's type, key properties, and children to a configurable depth.

**Params:**
- `path` (string, required) — Node path from `find_nodes`
- `depth` (int, optional, default 2) — Levels of children to include

**Result:** Nested dictionary tree. Each node includes `name`, `class`, `visible`. Class-specific properties are included automatically: `text` for Labels, `current_tab`/`tab_names` for TabContainers, `title`/`folded` for FoldableContainers.

#### `read_node_text`
Recursively harvest all visible text content from a subtree in document order. This is the primary method for verifying that a GUI widget displays sensible output.

**Params:**
- `path` (string, required) — Node path to walk
- `max_labels` (int, optional, default 200) — Maximum entries to return

**Result (example):**
```json
{
  "path": "/root/.../MyPanel",
  "entries": [
	{"type": "tab_container", "name": "TabContainer", "current_tab": 0, "tab_names": ["Tab1", "Tab2"]},
	{"type": "section", "title": "Section A", "folded": true},
	{"type": "section", "title": "Section B", "folded": false},
	{"type": "label", "name": "value_label", "text": "85"},
	{"type": "label", "name": "rate_label", "text": "2.5"}
  ],
  "count": 5,
  "truncated": false
}
```

**Behavior:**
- Skips invisible nodes entirely
- For TabContainers, only recurses the active tab
- For FoldableContainers, skips folded sections
- Stops at `max_labels` entries, sets `truncated: true`

**Timing note:** Some projects populate GUI content asynchronously (e.g., via deferred calls or background threads). `read_node_text` reads the current display state — it does not trigger or wait for updates. If labels are empty, the data may not yet have populated. Callers should ensure the relevant GUI is active and data has had time to load (e.g., navigate with `select_body`, wait ~2 seconds, then inspect).

**Recommended AI workflow** for "test X for sensible output":
1. `get_state` — confirm simulator running
2. `select_body` — navigate to entity with data
3. Wait ~2 seconds for data population
4. `find_nodes` with `script_class` — discover the node path
5. `read_node_text` with that path — harvest visible text
6. Analyze entries for non-empty values, reasonable numeric ranges, correct section titles

### 4.9 Mouse Hover Identification

Three primitives for verifying the user-visible effect of any system that identifies on-screen elements at the mouse position (today this is `IVFragmentIdentifier`'s shader-encoded ids on asteroid points and orbit lines). Capability: `mouse_hover`.

This suite intentionally observes [`IVMouseTargetLabel.text`](../ivoyager_core/ui/mouse_target_label.gd) — the label the user actually sees — rather than any specific identifier API. Tests written against these methods remain valid across replacement of the underlying identification mechanism (e.g. a future Compositors-based system replacing `IVFragmentIdentifier`).

#### `warp_mouse`
Synthesize an `InputEventMouseMotion` at a viewport pixel position. Updates `IVWorldController.mouse_position` (and any other input subscribers) the same way an OS-generated mouse event would, without moving the visible OS cursor.

**Params:**
- `position` (array, required) — `[x, y]` in viewport pixel coordinates

**Result:**
```json
{"ok": true, "position": [640.0, 360.0]}
```

#### `project_to_screen`
Project a 3D world position to a viewport pixel via the active `Camera3D.unproject_position()`. Use to find good test coordinates for hover assertions: project a body for body-pixel hover, project a body at a future time to land on its orbit line, project an asteroid for SBG-point hover.

**Params (exactly one of `body`, `world_position`, or `small_body` required):**
- `body` (string) — Body name; projects the body's current Node3D `global_position` (already in Godot scene-tree world coordinates).
- `time` (float, optional, only with `body`) — TT J2000 seconds. When supplied, projects the body's position at that time (computed by walking the parent chain, summing each ancestor's per-parent local orbit position, and anchoring at the topmost body's `global_position`). A `time` other than current places the projected pixel on the body's orbit line where the body itself isn't — the hook for orbit-line hover testing.
- `world_position` (array) — `[x, y, z]` in Godot scene-tree world coordinates (the same space as any `Node3D.global_position` in the scene). Note: position values returned by `get_body_position` / `get_body_state_vectors` are in Godot scene-tree units relative to the body's parent (not heliocentric world); anchor them by adding the parent body's `global_position` if you need world-space input here.
- `small_body` (object) — Asteroid in an [`IVSmallBodiesGroup`](../ivoyager_core/tree/small_bodies_group.gd) by index, with sub-keys:
  - `group` (string, required) — SBG name (discover via `list_small_body_groups`).
  - `index` (int, required) — Element index within the group, `[0, count)`.

  Projects the asteroid's current heliocentric position, computed from its stored Keplerian elements (precession ignored — see "Limitations" below). Lagrange-point (Trojan) groups are not supported and return ERR_INVALID_PARAMS.

**Result:**
```json
{
  "position": [820.5, 412.0],
  "on_screen": true,
  "behind_camera": false,
  "world_position_used": [-329046784.0, 235556144.0, -161255408.0]
}
```

For `small_body`, the response also includes `"name": "<asteroid name>"` (the entry from `IVSmallBodiesGroup.names`). `on_screen` is `true` only when `behind_camera` is `false` AND the projected pixel is inside the viewport rect. `world_position_used` is the Godot scene-tree world coordinate that was projected — useful for diagnosing scale or anchoring mismatches when projections land off-screen unexpectedly.

**Limitations of asteroid projection:**
- Trojan / Lagrange-point groups (`lp_integer != -1`) are rejected; their librating positions need a different model.
- Precession of LAN and AP (rates from `IVSmallBodiesGroup.s_g_mag_de`) is not applied. For main-belt asteroids the per-decade drift is well within `IVFragmentIdentifier`'s ~9-pixel sample radius, so the projected pixel still falls inside the rendered point's identification grid for typical sim time deltas from epoch.

#### `list_small_body_groups`
Enumerate loaded `IVSmallBodiesGroup` instances. Useful for discovering valid `small_body.group` values for `project_to_screen`.

**Params:** none

**Result:**
```json
{
  "groups": [
	{"name": "MPC_NEAR_EARTH_OBJECTS", "alias": "NEAs", "count": 1234, "lp_integer": -1},
	{"name": "JT4", "alias": "JT4", "count": 5678, "lp_integer": 4}
  ]
}
```

`lp_integer` is `-1` for normal heliocentric groups; `4` or `5` for Jupiter Trojans (L4/L5). Trojan groups cannot be passed to `project_to_screen` (see Limitations above).

#### `get_hover_target`
Return the current state of `IVMouseTargetLabel` — the user-visible identification of whatever shader element is under the mouse.

**Params:** none

**Result:**
```json
{
  "text": "Mars (orbit)",
  "visible": true,
  "mouse_position": [830.0, 412.0]
}
```

**Timing note:** `IVFragmentIdentifier` samples a SubViewport and runs an 8-frame calibration/value cycle before reporting an id. Allow ~250–400 ms (≥ ~16 frames at 60 Hz, doubling the cycle length for safety) between `warp_mouse` and the first reliable `get_hover_target` reading. Replacement implementations may have different timing — clients should poll `get_hover_target` until the text stabilizes rather than relying on a fixed delay.

**Recommended hover-test workflow:**
1. `move_camera` to a vantage point that puts the test target on-screen.
2. Wait ~1 s for camera and HUDs to settle.
3. `project_to_screen` with `body` to get the body's projected pixel.
4. `warp_mouse` to that pixel (or a small offset for orbit-line tests).
5. Sleep / poll briefly; call `get_hover_target` and assert on `text`.

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
| `IVMouseTargetLabel` | Found under `IVGlobal.program[&"TopUI"]` | Read `text` / `visible` for hover-target identification (independent of the underlying identifier mechanism) |
| `Camera3D` | Via `Viewport.get_camera_3d()` | `unproject_position()` for world-to-screen projection |
| `IVSmallBodiesGroup` | Static `small_bodies_groups` registry + `get_orbit_elements()` / `names` | Asteroid enumeration and per-asteroid Keplerian elements for `project_to_screen {small_body}` |
| `IVOrbit` | Static `get_true_anomaly_from_mean_anomaly_elliptic()` and `get_position_from_elements_at_true_anomaly()` | Asteroid position from elements at current sim time |
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

[assistant_test_suites]
StateQuerySuite="res://addons/ivoyager_assistant/test_suites/state_query_suite.gd"
ControlSuite="res://addons/ivoyager_assistant/test_suites/control_suite.gd"
CoreTestSuite="res://addons/ivoyager_assistant/test_suites/core_test_suite.gd"
GuiInspectionSuite="res://addons/ivoyager_assistant/test_suites/gui_inspection_suite.gd"

[assistant]
port=29071
enabled=true
debug_only=true
assistant_name=""
context_file=""
min_ready_delay_frames=10
```

### 7.1 Autoload Registration

The `[assistant_autoload]` section declares autoloads managed by the EditorPlugin. When the plugin is enabled in Godot's Plugin manager, `IVAssistantServer` is registered as an autoload. Projects can negate the autoload by setting `IVAssistantServer=""` in `ivoyager_override.cfg`.

### 7.2 Test Suites

The `[assistant_test_suites]` section registers `IVAssistantTestSuite` subclasses that provide API methods to the server. Each entry maps a suite name to a GDScript file path. The server loads these at startup, calls `_init_test_suite()` on each, and builds a method dispatch table from their `get_method_names()` return values.

**Default suites:**

| Suite | Methods |
|---|---|
| `StateQuerySuite` | `get_time`, `get_selection`, `get_camera`, `list_bodies`, `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance`, `get_body_state_vectors` |
| `ControlSuite` | `select_body`, `select_navigate`, `set_pause`, `set_speed`, `set_time`, `move_camera`, `show_hide_gui`, `list_actions`, `press_action` |
| `CoreTestSuite` | `screenshot`, `save_game`, `load_game`, `get_save_status` |
| `GuiInspectionSuite` | `find_nodes`, `inspect_node`, `read_node_text` |
| `MouseTargetIdSuite` | `warp_mouse`, `project_to_screen`, `get_hover_target` |
| `SmallBodiesIdSuite` | `project_small_body_to_screen`, `list_small_body_groups` |

**Override examples** (in `ivoyager_override.cfg` or `ivoyager_override2.cfg`):

```ini
[assistant_test_suites]
; Remove a suite entirely:
CoreTestSuite=null

; Replace a suite with a custom implementation:
StateQuerySuite="res://custom/my_query_suite.gd"

; Add a new suite alongside the defaults:
MyProjectTests="res://tests/my_project_tests.gd"
```

Setting a suite to `null` or `""` removes it. Adding a new key registers a new suite. If two suites register the same method name, the last one loaded wins (with a warning).

**Creating a custom test suite:**

Extend `IVAssistantTestSuite` and override:
- `get_method_names()` — Return the method names your suite handles
- `get_method_requirements()` — Map<method_name, Array[String]> of requirement tokens (see §7.5). Methods whose tokens evaluate false at load time (or at `simulator_started`, for widget tokens) are dropped from the dispatch table and reported in `gated_out`.
- `get_method_summaries()` — Optional Map<method_name, String> of one-line summaries surfaced in the `methods` field of `get_project_info`.
- `is_applicable()` — Return `false` to opt out of the entire suite. Use for all-or-nothing dependencies that don't fit the per-method token vocabulary (e.g. an asteroid-only suite checking `&"asteroids" in IVCoreSettings.body_tables`).
- `get_capabilities()` — Return additional capability strings (feature-group identifiers, e.g. `"mouse_hover"`) that aren't method names. Most suites can leave this empty: the server already advertises every active method name in `capabilities`.
- `dispatch(method, params)` — Handle method calls, return result or `_error` dict
- `requires_sim_started()` — Return `false` if some methods work before sim starts (default: `true`)
- `_on_simulator_started()` / `_on_about_to_free()` — Cache/clear program references

The suite receives the server node via `_init_test_suite(server)`. Use `_server.get_viewport()` for viewport access and `_server.parse_vector3()` / `_server.get_global_position()` for shared utilities.

### 7.3 Runtime Settings

The `[assistant]` section controls runtime behavior:

- `port` — TCP listen port (default: 29071)
- `enabled` — Master enable/disable (default: true). When false, the autoload node exists but does not start the TCP server.
- `debug_only` — If true, server only starts when `OS.is_debug_build()` is true (default: true)
- `assistant_name` — Display name for the assistant persona (default: empty, uses project name from ProjectSettings)
- `context_file` — Path to a text file (`res://` relative) with project-specific context for AI clients (default: empty)
- `min_ready_delay_frames` — Number of consecutive frames the project's `ready_predicate` must return `true` (after `simulator_started`) before sim-gated methods become available (default: 10). Allows projects with deferred main-thread work after `simulator_started` (e.g. cross-thread initialization arriving via `call_deferred`) to settle before save/load and similar operations are permitted. See §7.4.

Base values in `ivoyager_assistant.cfg` can be overridden per-project via `ivoyager_override.cfg` or `ivoyager_override2.cfg`.

### 7.4 Project-supplied readiness predicate

Projects with cross-thread or deferred initialization that continues past `simulator_started` can supply a readiness predicate that the server polls each frame:

```gdscript
IVAssistantServer.ready_predicate = func() -> bool:
	return MyProject.is_initialization_complete
```

The readiness gate stays closed until the predicate has returned `true` for `min_ready_delay_frames` consecutive frames (counted from the first frame the predicate returns `true`, not from `simulator_started`). If the predicate flips back to `false` while counting, the countdown resets. Once the gate has opened, it stays open until reset by `IVStateManager.about_to_free_procedural_nodes` (e.g. during a load).

The default predicate is trivially `true`, so projects that don't set `ready_predicate` get only the `min_ready_delay_frames` buffer after `simulator_started`.

Test suites that opt out of the suite-wide gate (`requires_sim_started()` returns `false`) can still consult the gate per-method via `IVAssistantServer.is_ready()`. The bundled `CoreTestSuite` uses this for `save_game` and `load_game` so save/load races against deferred initialization are blocked even when the suite handles other methods (e.g. `get_save_status`) pre-simulator.

### 7.5 Requirement-Token Vocabulary

`IVAssistantTestSuite.get_method_requirements()` returns a Map<method_name, Array[String]>. Each string is a requirement token from the closed vocabulary defined in `IVAssistantServer.KNOWN_TOKENS`. Unknown tokens `push_error` at suite load and are dropped (the method is then registered as unconditionally available, matching the suite-author's intent of "no recognized restriction").

A method is **active** (callable, listed in `capabilities`, listed under `methods` in `get_project_info`) iff every token in its requirement list resolves true. Methods with at least one unmet token are dropped from the dispatch table — calling one returns `ERR_UNKNOWN_METHOD`, identical to a never-implemented method — and are listed under `gated_out` in `get_project_info` with the unmet token names.

The vocabulary:

| Token | Resolves to |
|---|---|
| `core.allow_time_setting` | `IVCoreSettings.allow_time_setting` |
| `core.allow_time_reversal` | `IVCoreSettings.allow_time_reversal` |
| `program.TopUI` | `IVGlobal.program.has(&"TopUI")` |
| `program.SpeedManager` | `IVGlobal.program.has(&"SpeedManager")` |
| `program.Timekeeper` | `IVGlobal.program.has(&"Timekeeper")` |
| `program.CameraHandler` | `IVGlobal.program.has(&"CameraHandler")` |
| `autoload.IVSave` | autoload at `/root/IVSave` is present |
| `body_table.stars` | `&"stars" in IVCoreSettings.body_tables` |
| `body_table.planets` | `&"planets" in IVCoreSettings.body_tables` |
| `body_table.moons` | `&"moons" in IVCoreSettings.body_tables` |
| `body_table.asteroids` | `&"asteroids" in IVCoreSettings.body_tables` |
| `body_table.spacecrafts` | `&"spacecrafts" in IVCoreSettings.body_tables` |
| `widget.MouseTargetLabel` | `IVMouseTargetLabel` reachable under `program.TopUI` after `simulator_started` |
| `runtime.IVSmallBodiesGroup` | `IVSmallBodiesGroup.small_bodies_groups` non-empty after `simulator_started` |

`core.*`, `program.*`, `autoload.*`, and `body_table.*` tokens resolve at `core_initialized` time (when suites load). `widget.*` and `runtime.*` tokens are evaluated against post-init state on `simulator_started`; before sim start they resolve false (the gated method is not active). After sim start the gating refreshes once. Clients querying `get_project_info` before vs after `start_game` see different `capabilities` / `gated_out` lists for those tokens — the post-start query is authoritative.

Suites that need a coarser opt-out than the per-method vocabulary supports can override `is_applicable() -> bool` to short-circuit registration entirely. The check fires once at `core_initialized`, so `is_applicable()` is the right tool for config-driven all-or-nothing decisions (e.g. a flag in `IVCoreSettings` that a project sets in its preinitializer). For runtime conditions known only after the system tree is built, use a per-method `runtime.*` requirement instead.

To extend the vocabulary, add an entry to `KNOWN_TOKENS` and a corresponding case in `_evaluate_token()` in `assistant_server.gd`. Tokens are stringly-typed and validated at suite load, so typos in suite code surface immediately as a `push_error`.

## 8. Cross-Project Compatibility

The plugin is designed as a git submodule usable across any I, Voyager project. Enable the plugin in Project Settings → Plugins — no project-level config changes are needed.

### 8.1 Feature Availability

Not all projects support all features. `get_project_info` returns three related fields that describe the current configuration:

- `capabilities` — Flat string array of every active method name plus suite-supplied feature flags (e.g. `"mouse_hover"`). This is the canonical source for AI clients deciding whether to call a method.
- `methods` — Map<method_name, {summary?: String}> covering every active method. The shape is reserved for future per-method metadata; today only the optional `summary` is populated.
- `gated_out` — Array of `{"method": String, "unmet": Array[String]}` entries, one per registered-but-currently-unavailable method, naming the requirement tokens that resolved false. Lets clients distinguish "this build doesn't support X" from "X doesn't exist."

Gating is driven by the per-method requirement-token vocabulary (see §7.5). Concretely:

- **Program objects**: Methods declaring `program.TopUI`, `program.CameraHandler`, `program.SpeedManager`, or `program.Timekeeper` only activate when those program objects are registered.
- **Settings**: `set_time` declares `core.allow_time_setting`, so it activates only when `IVCoreSettings.allow_time_setting == true`.
- **Project type**: `start_game` is hard-coded into `capabilities` only for projects with `IVCoreSettings.wait_for_start == true`.
- **Plugins**: `save_game`, `load_game`, and `get_save_status` declare `autoload.IVSave`, so they activate only when the `ivoyager_save` plugin is present.
- **Small-bodies groups**: `SmallBodiesIdSuite`'s `project_small_body_to_screen` and `list_small_body_groups` declare `runtime.IVSmallBodiesGroup`. They activate only after `simulator_started` if `IVSmallBodiesGroup.small_bodies_groups` has at least one entry — i.e. the project's `small_bodies_groups` table has any non-`skip` rows and `IVTableSystemBuilder.add_small_bodies_groups` is true. (This is **not** the same as `body_table.asteroids`: that flag controls whether the few "explored" asteroids are loaded as `IVBody` instances; the SBG point clouds the suite actually targets are populated from the separate `small_bodies_groups` table.)
- **Widgets**: `get_hover_target` declares `widget.MouseTargetLabel` and activates only after `simulator_started` if an `IVMouseTargetLabel` is reachable under `program.TopUI`.

Calling a gated-out method returns `ERR_UNKNOWN_METHOD`. The protocol intentionally collapses "method not implemented" and "method gated out by configuration" into the same error: a missing capability looks identical to a never-implemented one, which is what clients should treat it as. The `gated_out` list is informational — clients that want to explain *why* a method is unavailable can read it.

The manifest version is reported as `assistant_protocol_version` (currently `2`); fields are added additively across versions.

### 8.2 Splash Screen Handling

Projects with `wait_for_start = true` display a splash screen before starting the simulation. The TCP server starts on `core_initialized` (before the splash screen), allowing AI clients to:

1. Connect and call `get_project_info` to discover the project
2. Poll `get_state` to check `started` status
3. Call `start_game` to programmatically start the simulation (bypassing the splash screen)

### 8.3 Project Identity

Projects can customize the assistant's identity via config:
- `assistant_name` — Gives the assistant a project-specific name
- `context_file` — Points to a text file with background information, personality guidelines, or project-specific instructions for AI clients

## 9. Generic Test Sequence

This section describes how to launch, connect, and run the generic tests that the Assistant plugin provides. These tests verify basic simulation functionality and work across all I, Voyager projects with the plugin enabled.

### 9.1 Launch

Run the Godot project from the command line in debug mode. Portable Godot executables are in the parent directory of the project (`../`). Use the most recent `*_console.exe` (sort by version) with `--path` pointing to the project directory:

```
../Godot_v4.6.1-stable_win64_console.exe --path .
```

The console variant outputs to stdout/stderr, which is useful for observing errors during testing.

### 9.2 Connect

Connect via TCP to `127.0.0.1:29071`. The server starts listening on `core_initialized`, which may take a few seconds after launch. Retry the connection with a short delay (e.g., 2 seconds) if refused.

### 9.3 Test Steps

Execute these steps in order:

1. **Discover capabilities:** Call `get_project_info`. Check `wait_for_start`, `started`, and `capabilities` in the response.
2. **Start the simulation:** If `wait_for_start` is `true` and `started` is `false`, call `start_game`. Then poll `get_state` until `started` is `true`.
3. **Verify state:** Call `get_state`, `get_time`, `get_selection`, `get_camera` and confirm reasonable values.
4. **Exercise controls:** Call `select_body` (e.g., `{"name": "PLANET_MARS"}`), `move_camera` (e.g., `{"target": "PLANET_EARTH", "instant": true}`), `set_pause`, `set_speed`.
5. **Save/load cycle** (if `save_game` and `load_game` are in capabilities): Call `save_game`, then poll `get_state` until `is_saving` is `false`. Call `load_game`, then poll `get_state` until `is_loading` is `false` and `started` is `true`.
6. **Quit:** Call `quit` with `{"force": true}` to shut down without a confirmation dialog.

### 9.3.1 Automated Test Runner

The file `tools/assistant_test.py` implements the full test sequence above as an automated Python script. It requires Python 3 (stdlib only, no dependencies). Usage:

```
python tools/assistant_test.py                  # game already running on port 29071
python tools/assistant_test.py --launch         # start Godot automatically, then test
python tools/assistant_test.py --skip-save      # skip the save/load cycle
python tools/assistant_test.py --port 29072     # custom port
```

The script is capability-aware: it checks the `capabilities` array from `get_project_info` and skips tests for features the project does not support. Exit code is 0 on success, 1 on failure.

### 9.4 Key Notes

- **Async save/load:** `save_game` and `load_game` return `{"ok": true}` immediately. Poll `get_state` to check `is_saving`/`is_loading` for completion. During load, most methods return error code 4 — only `get_state` and `get_save_status` remain available.
- **Error code 4 (simulator not ready):** If received, poll `get_state` and retry. This occurs before `start_game` completes, during load operations, and during the readiness-gate delay after `simulator_started` (default 10 frames; longer if the project supplies a `ready_predicate`). Note that `started == true` is necessary but not sufficient — sim-gated methods may briefly continue to return error 4 after `started` flips true while the readiness gate is still closing its delay window. Simply retry on error 4.
- **Per-frame processing:** Commands are processed once per frame (~60 Hz). Between a request and its response, at least one game frame passes.
- **Capabilities are authoritative:** Only call methods listed in the `capabilities` array from `get_project_info`. Missing capabilities indicate the project lacks the required program objects or plugins.
