# I, Voyager Assistant — Coding Plan

## Phase 1: TCP Server and Basic Testing Interface

**Goal:** Enable Claude Code to connect to the running simulation, query state, and exercise basic controls. This is the prerequisite for AI-assisted development testing.

### Step 1.1: Create AssistantPreinitializer

**File:** `addons/ivoyager_assistant/assistant_preinitializer.gd`

- Extends `RefCounted`
- In `_init()`:
  - Register `AssistantServer` in `IVCoreInitializer.program_nodes`
  - Read config from `ivoyager_assistant.cfg` `[assistant]` section
  - Skip registration if `enabled == false` or (`debug_only == true` and not debug build)
- Follow the pattern in `planetarium/preinitializer.gd`

**Config change:** Append to `ivoyager_override.cfg`:
```ini
preinitializers/AssistantPreinitializer="res://addons/ivoyager_assistant/assistant_preinitializer.gd"
```

### Step 1.2: Create AssistantServer Node

**File:** `addons/ivoyager_assistant/assistant_server.gd`

- Extends `Node`
- Properties:
  - `_tcp_server: TCPServer`
  - `_clients: Array[StreamPeerTCP]`
  - `_port: int` (from config, default 29071)
  - `_buffers: Dictionary` (client -> partial read buffer)
- `_ready()`: connect to `IVStateManager.simulator_started` and `IVStateManager.about_to_quit`
- `_on_simulator_started()`: create and start `TCPServer` on configured port
- `_process()`:
  - Accept new connections from `_tcp_server.take_connection()`
  - For each client: read available bytes, append to buffer, extract complete lines (split on `\n`)
  - Parse each complete line as JSON, dispatch to handler method, write JSON response + `\n`
  - Remove disconnected clients
- `_on_about_to_quit()`: stop server, disconnect clients

### Step 1.3: Implement State Queries

Implement these methods in AssistantServer:

- **`get_state`** — Read `IVStateManager` flags (`started`, `running`, `paused_tree`, `paused_by_user`, `building_system`), `IVGlobal.times`, `IVGlobal.date`, `IVGlobal.clock`, speed info from `SpeedManager`
- **`get_time`** — Detailed time from `Timekeeper` and `IVGlobal.times`
- **`get_selection`** — Get `SelectionManager` from TopUI, read name, gui_name, body flags
- **`list_bodies`** — Iterate `IVBody.bodies` keys, optionally filter by `BodyFlags`

### Step 1.4: Implement Basic Controls

- **`select_body`** — Call `selection_manager.select_by_name()`
- **`set_pause`** — Call `IVStateManager.set_user_paused()`
- **`set_speed`** — Call `speed_manager.change_speed()`, `increment_speed()`, or `decrement_speed()`

### Step 1.5: Add Configuration

Update `ivoyager_assistant.cfg`:
```ini
[assistant]
port=29071
enabled=true
debug_only=true
```

### Step 1.6: Create Claude Code Helper Script

**File:** `addons/ivoyager_assistant/tools/assistant_client.sh`

A bash script wrapping netcat for easy command-line interaction:
```
Usage: ./assistant_client.sh <method> [params_json]
Example: ./assistant_client.sh get_state
Example: ./assistant_client.sh select_body '{"name":"PLANET_MARS"}'
```

### Step 1.7: Basic Smoke Test

After Phase 1 implementation, verify by:
1. Run the Planetarium in Godot Editor (press Play)
2. From a terminal, run: `echo '{"id":1,"method":"get_state"}' | nc localhost 29071`
3. Verify JSON response with `started: true`, `running: true`
4. Run: `echo '{"id":2,"method":"list_bodies","params":{"filter":"planets"}}' | nc localhost 29071`
5. Verify response lists all 8 planets
6. Run: `echo '{"id":3,"method":"select_body","params":{"name":"PLANET_MARS"}}' | nc localhost 29071`
7. Verify Mars is selected in the GUI

---

## Phase 2: Body Information and Camera Control ✓

**Goal:** Enable querying detailed body properties and controlling the camera for comprehensive testing.

### Step 2.1: Body Information Queries ✓

- **`get_body_info`** — Returns `name`, `gui_name`, `flags`, `mean_radius`, `gravitational_parameter`, `parent`, `satellites`
- **`get_body_position`** — Calls `body.get_position_vector(time)`, returns `[x, y, z]` position relative to parent
- **`get_body_orbit`** — Returns `semi_major_axis`, `eccentricity`, `inclination`, `longitude_ascending_node`, `argument_periapsis`, `period` via IVOrbit element accessors
- **`get_body_distance`** — Computes global positions by chaining parent positions up the tree, returns Euclidean distance

### Step 2.2: Camera Control ✓

- **`get_camera`** — Returns target, flags, view_position, view_rotations, is_camera_lock via `CameraHandler.get_camera_view_state()` plus viewport camera property
- **`move_camera`** — Calls `CameraHandler.move_to_by_name()` or `move_to()` with optional target, view_position, view_rotations, instant parameters

### Step 2.3: Time Control ✓

- **`set_time`** — Three modes: absolute TT seconds via `Timekeeper.set_time()`, Gregorian date via `set_time_from_date_clock_elements()`, or OS sync via `synchronize_with_operating_system()`. Validates dates with `IVTimekeeper.is_valid_gregorian_date()`. Requires `IVCoreSettings.allow_time_setting == true`.

### Step 2.4: Selection Navigation ✓

- **`select_navigate`** — Maps 16 direction strings to `IVSelectionManager` navigation methods: up, down, next, last, next/last_planet, next/last_moon, next/last_major_moon, next/last_star, next/last_spacecraft, history_back, history_forward. Checks `has_*()` before calling `select_*()`.

---

## Phase 3: Testing Framework

**Goal:** Add utilities specifically designed for automated test scenarios.

### Step 3.1: Screenshot Capture

- **`screenshot`** — `get_viewport().get_texture().get_image().save_png(path)`
- Returns file path for Claude Code to read via the Read tool

### Step 3.2: Validation Helpers

- **`get_body_state_vectors`** — Returns both position and velocity vectors
- Bulk query methods for testing orbital mechanics across multiple bodies

---

## Phase 4: GUI Manipulation

**Goal:** Enable programmatic control of all GUI elements.

### Step 4.1: GUI Visibility

- **`show_hide_gui`** — Emit `IVGlobal.show_hide_gui_requested`
- **`get_gui_state`** — Report visibility of panels

### Step 4.2: Settings and Options

- **`set_option`** — Change user settings via `IVSettingsManager`
- **`get_options`** — Read current settings

### Step 4.3: HUD Controls

- Toggle body labels, orbit lines, asteroid visibility via `BodyHUDsState` and `SBGHUDsState`

---

## Phase 5: Accessibility

**Goal:** Make the Planetarium accessible via voice control and screen readers.

### Step 5.1: Voice Command Interface

- Design grammar mapping natural language to API methods
- Integration with speech-to-text services

### Step 5.2: Screen Reader Support

- Text descriptions of current view and selected body
- Announce state changes

### Step 5.3: Spatial Audio

- Audio cues for body positions relative to camera
- Directional feedback for navigation
