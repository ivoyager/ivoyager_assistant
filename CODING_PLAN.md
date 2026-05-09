# I, Voyager Assistant — Coding Plan

## Status

v0.0.1.dev. The TCP server, modular test suite architecture, and the generic state / control / body / camera / time / selection / speed / save / load / GUI-inspection / screenshot / action-emulation APIs are all in place, plus a Python test runner. Remaining work centers on settings/HUD typed APIs and accessibility.

For the per-method addition history, see `CHANGELOG.md`. For the protocol and configuration reference, see `SPECIFICATION.md`.

## Completed

- **Phase 1–2** — TCP server + JSON-RPC protocol; state/body/camera/time/selection/speed APIs; basic controls (`select_body`, `set_pause`, `set_speed`); EditorPlugin autoload registration.
- **Phase 2.5 — Cross-project compatibility** — two-phase startup (`core_initialized` → `simulator_started`); `get_project_info`, `start_game`; `assistant_name` / `context_file` config keys; graceful sim reset on `about_to_free_procedural_nodes`.
- **Phase 3 — Testing utilities** — `screenshot` (with `hide_gui`), `show_hide_gui`, `get_body_state_vectors`.
- **Phase 3b — Action emulation** — `list_actions`, `press_action`.
- **Phase 3c — Modular test suite architecture** — `IVAssistantTestSuite` RefCounted base class, `[assistant_test_suites]` config section, four default suites; server reduced to TCP infrastructure plus four built-in methods.
- **GUI inspection** (`GuiInspectionSuite`) — `find_nodes`, `inspect_node`, `read_node_text`. Generic scene-tree introspection that subsumes much of the originally planned Phase 4.
- **Save/load** (in `CoreTestSuite`) — `save_game`, `load_game`, `get_save_status`. Available only when `ivoyager_save` is present.
- **Readiness gate** — `ready_predicate` + `min_ready_delay_frames` + `IVAssistantServer.is_ready()`. Lets projects with deferred main-thread initialization gate save/load and similar operations until state has settled.
- **Test runner** — `tools/assistant_test.py` implements the SPECIFICATION.md §9.3 sequence; capability-aware, skips unsupported features.

## Next: Phase 4 — Settings & HUD typed API

**Goal:** add typed, named accessors for user settings and HUD state, complementing the generic `find_nodes` / `inspect_node` introspection that already exists.

`get_gui_state` from the original Phase 4 plan is **superseded** by the GUI inspection suite (`SPECIFICATION.md` §4.8) and is dropped. The remaining items:

### Step 4.1: Settings

- **`set_option`** — Change a user setting via `IVSettingsManager`.
  - **Params:** `setting` (string, required), `value` (variant, required).
  - **Result:** `{"ok": true, "setting": "...", "value": ...}`.
- **`get_options`** — Read current settings as a dict (or read a single setting if `setting` param is supplied).

### Step 4.2: HUD toggles

- Toggle body labels, orbit lines, and asteroid visibility via `BodyHUDsState` / `SBGHUDsState` flags.
- Likely shape: a single `set_huds` method that takes a dict of flag → bool, plus a `get_huds` reader. Final shape TBD when implementing.

These are *typed* APIs — they expose state by named flag, not by GUI text. The generic `find_nodes` / `read_node_text` route remains the right tool for asserting that GUI text *renders* correctly; this Phase 4 is about programmatic state control.

## Next: Phase 5 — Accessibility

**Goal:** make the Planetarium navigable via voice control and screen readers.

Purely conceptual at this stage; no detailed API yet.

### Step 5.1: Voice command interface

- Design grammar mapping natural language to existing API methods.
- Integration with speech-to-text services.

### Step 5.2: Screen reader support

- Text descriptions of current view and selected body.
- Announce state changes.

### Step 5.3: Spatial audio

- Audio cues for body positions relative to camera.
- Directional feedback for navigation.
