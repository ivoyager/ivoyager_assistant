# I, Voyager Assistant — Coding Plan

## Status

v0.0.1.dev. The TCP server, modular test suite architecture, and the generic state / control / body / camera / view / time / selection / speed / save / load / GUI-inspection / screenshot / action-emulation APIs are all in place, plus a Python test runner. Remaining work centers on settings/HUD typed APIs and accessibility.

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
- **Phase 3d — Mouse hover identification** (`MouseHoverSuite`) — `warp_mouse`, `project_to_screen`, `get_hover_target`. Lets tests verify that hovering at a given screen position identifies the expected element by reading `IVMouseTargetLabel.text`. The suite never references `IVFragmentIdentifier` directly, so it serves as a regression safety net for the upcoming replacement of that class with a more efficient identifier (e.g. Compositors-based) — tests written today should continue to pass after the swap, validating that the user-visible effect is preserved.

- **Phase 3e — Views** (`ViewSuite`) — `list_views`, `apply_view`. Binds Tier-1 camera framing to `IVViewManager.set_table_view` — the same Core call the GUI's default `IVViewButton` makes — so an agent frames the camera the way a user clicks a view button, instead of hand-building a perspective-distance vector through `move_camera`. `list_views` decodes each table view's target, tracking mode, up-lock, framing vector, and affected state categories (`IVView` has no description field). Scope is table views only; user/cached views are deferred to "Suite B". Established the "Core surface classes / layering principle" (`SPECIFICATION.md` §10): Assistant methods bind to the same Core entry points GUI widgets do, at the same level; sub-surface access (e.g. `move_camera`) is the marked exception. Also corrected the `IVCamera` / `IVCameraHandler` / `IVViewManager.set_table_view` doc comments to state the perspective-distance contract in caller terms and point to views as the normal path.

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

## Next: Suite B — Generic widget actuation (deferred)

The write-side sibling of `GuiInspectionSuite` (`SPECIFICATION.md` §4.8 read-side). Where `find_nodes` / `inspect_node` / `read_node_text` *read* the GUI tree, Suite B would *actuate* a bounded set of `Control` widgets by node path, so an agent (or accessibility client) can drive any GUI panel without a typed Core method per control. This is the generalization of the §10 layering principle to the widget level: it binds at the `Control` surface for GUI that has no typed Core accessor.

**Bounded Control vocabulary** (one method per family, or a single `set_widget` dispatching on the resolved class):
- `Button` / `CheckBox` / `CheckButton` — press, or `set_pressed(bool)` for toggle types.
- `TabContainer` — set `current_tab` (int).
- `FoldableContainer` — set `folded` (bool).
- `Range` / `SpinBox` — set `value` (float).
- `OptionButton` — select by index / id.
- `LineEdit` / `TextEdit` — set `text`, optionally emit submit.

**Guards (the reason this is its own suite, not a quick add):**
- Respect `disabled` and `visible` — refuse to actuate a disabled or hidden control (return an error, never silently no-op).
- **Prefer the widget's real signal/setter over synthesizing OS input.** Emit `pressed` / call `set_pressed` / assign `value` directly (firing the widget's own `value_changed` etc.) rather than warping the mouse and faking a click — deterministic, headless-safe, and avoids the "below the GUI surface" hazard that motivated §10.
- Resolve the target by node path (reuse `GuiInspectionSuite`'s resolution) and validate the resolved class is in-vocabulary before acting.
- Echo the resulting state in the result (e.g. `{"ok": true, "pressed": true}`) so the client can confirm without a follow-up `inspect_node`.

Does **not** replace the typed Phase 4 Settings/HUD API — typed accessors stay the right tool for named state; Suite B is for arbitrary GUI controls with no typed Core accessor. Deferred behind Phase 4 because typed accessors cover the highest-value controls first; Suite B generalizes the remainder.

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
