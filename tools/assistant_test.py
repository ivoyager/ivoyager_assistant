#!/usr/bin/env python3
"""Generic I, Voyager test runner for the ivoyager_assistant TCP server.

Implements the full test sequence from SPECIFICATION.md section 9.3:
discover capabilities, start simulation, verify state, exercise controls,
save/load cycle, and quit. Tests are capability-aware and skip gracefully
when a project lacks specific features.

Usage:
    python assistant_test.py                  # game already running
    python assistant_test.py --launch         # start Godot automatically
    python assistant_test.py --skip-save      # skip save/load cycle
    python assistant_test.py --host HOST      # custom host (default: 127.0.0.1)
    python assistant_test.py --port PORT      # custom port (default: 29071)
"""

import argparse
import json
import socket
import subprocess
import sys
import time


# =============================================================================
# TCP Client
# =============================================================================

class AssistantClient:
    """TCP client for the ivoyager_assistant JSON-RPC server."""

    def __init__(self, host="127.0.0.1", port=29071, timeout=10.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock = None
        self._buffer = b""
        self._request_id = 0

    def connect(self, retries=30, delay=2.0):
        for attempt in range(retries):
            try:
                self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self._sock.settimeout(self.timeout)
                self._sock.connect((self.host, self.port))
                return
            except (ConnectionRefusedError, OSError):
                self._sock = None
                if attempt < retries - 1:
                    time.sleep(delay)
        raise ConnectionError(
            "Could not connect to %s:%d after %d attempts" % (self.host, self.port, retries)
        )

    def close(self):
        if self._sock:
            self._sock.close()
            self._sock = None

    def call(self, method, params=None):
        self._request_id += 1
        request = {"id": self._request_id, "method": method}
        if params:
            request["params"] = params
        line = json.dumps(request) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        return self._recv_response()

    def _recv_response(self):
        while True:
            newline_pos = self._buffer.find(b"\n")
            if newline_pos >= 0:
                line = self._buffer[:newline_pos]
                self._buffer = self._buffer[newline_pos + 1:]
                return json.loads(line.decode("utf-8"))
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Server closed connection")
            self._buffer += chunk


# =============================================================================
# Test Runner
# =============================================================================

class TestRunner:
    """Runs the generic I, Voyager test sequence (SPECIFICATION.md section 9)."""

    def __init__(self, client, skip_save=False):
        self.client = client
        self.skip_save = skip_save
        self.capabilities = []
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.errors = []

    def has_cap(self, name):
        return name in self.capabilities

    def assert_true(self, condition, message):
        if condition:
            self.passed += 1
            print("  PASS: %s" % message)
        else:
            self.failed += 1
            self.errors.append(message)
            print("  FAIL: %s" % message)

    def assert_gt(self, value, threshold, name):
        self.assert_true(value > threshold, "%s = %s (expected > %s)" % (name, value, threshold))

    def assert_eq(self, value, expected, name):
        self.assert_true(value == expected, "%s = %s (expected %s)" % (name, value, expected))

    def skip(self, message):
        self.skipped += 1
        print("  SKIP: %s" % message)

    def poll_state(self, condition_fn, description, timeout=60, interval=1.0):
        """Poll get_state until condition_fn(result) is True."""
        for _ in range(int(timeout / interval)):
            resp = self.client.call("get_state")
            result = resp.get("result", {})
            if condition_fn(result):
                return result
            time.sleep(interval)
        self.assert_true(False, "%s (timed out after %ds)" % (description, timeout))
        return None

    # =========================================================================
    # Test sequence
    # =========================================================================

    def run_all(self, print_summary=True):
        print("\n=== I, Voyager Generic Tests ===\n")

        self.test_1_discover()
        self.test_2_start()
        self.test_3_verify_state()
        self.test_4_exercise_controls()
        self.test_5_save_load()

        if print_summary:
            self.print_summary()
        return self.failed == 0

    def print_summary(self):
        print("\n=== Results: %d passed, %d failed, %d skipped ===" % (
            self.passed, self.failed, self.skipped))
        if self.errors:
            print("\nFailures:")
            for err in self.errors:
                print("  - %s" % err)

    # 9.3 Step 1: Discover capabilities
    def test_1_discover(self):
        print("[1. Discover capabilities]")
        resp = self.client.call("get_project_info")
        result = resp.get("result", {})
        self.capabilities = result.get("capabilities", [])

        self.assert_true(
            "get_state" in self.capabilities,
            "get_state capability"
        )
        self.assert_true(
            "quit" in self.capabilities,
            "quit capability"
        )
        self.assert_true(
            len(self.capabilities) > 2,
            "Multiple capabilities (%d found)" % len(self.capabilities)
        )

        project_name = result.get("project_name", "")
        project_version = result.get("project_version", "")
        print("  Project: %s %s" % (project_name, project_version))
        print("  Capabilities: %s" % ", ".join(sorted(self.capabilities)))

    # 9.3 Step 2: Start simulation
    def test_2_start(self):
        print("[2. Start simulation]")
        resp = self.client.call("get_project_info")
        result = resp.get("result", {})
        wait_for_start = result.get("wait_for_start", False)
        started = result.get("started", False)

        if wait_for_start and not started:
            self.assert_true(self.has_cap("start_game"), "start_game capability available")
            print("  Calling start_game...")
            self.client.call("start_game")

        state = self.poll_state(
            lambda s: s.get("started", False),
            "Simulator started",
        )
        if state:
            self.assert_true(True, "Simulator started")

    # 9.3 Step 3: Verify state
    def test_3_verify_state(self):
        print("[3. Verify state]")

        # get_state
        resp = self.client.call("get_state")
        result = resp.get("result", {})
        self.assert_true(result.get("started", False), "get_state: started")
        # is_saving/is_loading are only present when IVSave plugin is enabled.
        self.assert_eq(result.get("is_saving", False), False, "get_state: not saving")
        self.assert_eq(result.get("is_loading", False), False, "get_state: not loading")

        # get_time
        if self.has_cap("get_time"):
            resp = self.client.call("get_time")
            result = resp.get("result", {})
            date = result.get("date", [0, 0, 0])
            self.assert_gt(date[0], 0, "get_time: year")
            self.assert_true(1 <= date[1] <= 12, "get_time: month = %d (1-12)" % date[1])
            self.assert_true(1 <= date[2] <= 31, "get_time: day = %d (1-31)" % date[2])
        else:
            self.skip("get_time not available")

        # get_selection
        if self.has_cap("get_selection"):
            resp = self.client.call("get_selection")
            result = resp.get("result", {})
            self.assert_true("error" not in resp, "get_selection: no error")
        else:
            self.skip("get_selection not available")

        # get_camera
        if self.has_cap("get_camera"):
            resp = self.client.call("get_camera")
            result = resp.get("result", {})
            self.assert_true(len(result.get("target", "")) > 0, "get_camera: has target")
        else:
            self.skip("get_camera not available")

    # 9.3 Step 4: Exercise controls
    def test_4_exercise_controls(self):
        print("[4. Exercise controls]")

        # list_bodies — planets
        if self.has_cap("list_bodies"):
            resp = self.client.call("list_bodies", {"filter": "planets"})
            result = resp.get("result", {})
            bodies = result.get("bodies", [])
            self.assert_gt(len(bodies), 0, "list_bodies: planets found (%d)" % len(bodies))
            has_earth = "PLANET_EARTH" in bodies
            has_mars = "PLANET_MARS" in bodies
            self.assert_true(has_earth, "list_bodies: PLANET_EARTH")
            self.assert_true(has_mars, "list_bodies: PLANET_MARS")
        else:
            self.skip("list_bodies not available")

        # select_body
        if self.has_cap("select_body"):
            resp = self.client.call("select_body", {"name": "PLANET_MARS"})
            result = resp.get("result", {})
            self.assert_true(result.get("ok", False), "select_body: PLANET_MARS")
            # Verify selection changed
            if self.has_cap("get_selection"):
                resp = self.client.call("get_selection")
                result = resp.get("result", {})
                self.assert_eq(result.get("name", ""), "PLANET_MARS",
                               "get_selection: now PLANET_MARS")
        else:
            self.skip("select_body not available")

        # move_camera
        if self.has_cap("move_camera"):
            resp = self.client.call("move_camera",
                                    {"target": "PLANET_EARTH", "instant": True})
            result = resp.get("result", {})
            self.assert_true(result.get("ok", False), "move_camera: to PLANET_EARTH")
            # Camera target should update
            if self.has_cap("get_camera"):
                resp = self.client.call("get_camera")
                result = resp.get("result", {})
                self.assert_eq(result.get("target", ""), "PLANET_EARTH",
                               "get_camera: target is PLANET_EARTH")
        else:
            self.skip("move_camera not available")

        # set_pause
        if self.has_cap("set_pause"):
            # Pause
            resp = self.client.call("set_pause", {"paused": True})
            result = resp.get("result", {})
            self.assert_true(result.get("ok", False), "set_pause: paused")
            resp = self.client.call("get_state")
            self.assert_eq(resp.get("result", {}).get("paused_by_user", False), True,
                           "get_state: paused_by_user after pause")
            # Unpause
            resp = self.client.call("set_pause", {"paused": False})
            result = resp.get("result", {})
            self.assert_true(result.get("ok", False), "set_pause: unpaused")
            resp = self.client.call("get_state")
            self.assert_eq(resp.get("result", {}).get("paused_by_user", False), False,
                           "get_state: not paused_by_user after unpause")
        else:
            self.skip("set_pause not available")

        # set_speed
        if self.has_cap("set_speed"):
            resp = self.client.call("set_speed", {"index": 3})
            result = resp.get("result", {})
            self.assert_true(result.get("ok", False), "set_speed: index 3")
            self.assert_eq(result.get("speed_index", -1), 3,
                           "set_speed: confirmed index 3")
            # Reset to default
            self.client.call("set_speed", {"index": 0})
        else:
            self.skip("set_speed not available")

    # 9.3 Step 5: Save/load cycle
    def test_5_save_load(self):
        print("[5. Save/load cycle]")

        if self.skip_save:
            self.skip("save/load skipped (--skip-save)")
            return

        has_save = self.has_cap("save_game") and self.has_cap("load_game")
        if not has_save:
            self.skip("save_game/load_game not in capabilities")
            return

        # Save
        resp = self.client.call("save_game", {"type": "quicksave"})
        result = resp.get("result", {})
        self.assert_true(result.get("ok", False), "save_game: quicksave initiated")

        # Poll until save completes
        state = self.poll_state(
            lambda s: not s.get("is_saving", True),
            "Save completed",
            timeout=30,
        )
        if not state:
            return

        self.assert_true(True, "save_game: completed")

        # Verify save exists
        if self.has_cap("get_save_status"):
            resp = self.client.call("get_save_status")
            result = resp.get("result", {})
            self.assert_true(result.get("has_saves", False), "get_save_status: has saves")

        # Load
        resp = self.client.call("load_game")
        result = resp.get("result", {})
        self.assert_true(result.get("ok", False), "load_game: quickload initiated")

        # Poll until load completes and sim restarts
        state = self.poll_state(
            lambda s: not s.get("is_loading", True) and s.get("started", False),
            "Load completed and simulator restarted",
            timeout=30,
        )
        if not state:
            return

        self.assert_true(True, "load_game: completed and restarted")

        # Verify state is sane after load
        resp = self.client.call("get_state")
        result = resp.get("result", {})
        self.assert_true(result.get("started", False), "Post-load: started")
        self.assert_eq(result.get("is_saving", True), False, "Post-load: not saving")
        self.assert_eq(result.get("is_loading", True), False, "Post-load: not loading")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Generic I, Voyager test runner (SPECIFICATION.md section 9)")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=29071, help="Server port")
    parser.add_argument("--launch", action="store_true",
                        help="Launch Godot before testing")
    parser.add_argument("--godot", default=None,
                        help="Path to Godot executable")
    parser.add_argument("--project", default=None,
                        help="Path to project directory")
    parser.add_argument("--skip-save", action="store_true",
                        help="Skip save/load cycle")
    args = parser.parse_args()

    godot_proc = None
    if args.launch:
        godot = args.godot or "../Godot_v4.6.2-stable_win64_console.exe"
        project = args.project or "."
        print("Launching Godot: %s --path %s" % (godot, project))
        godot_proc = subprocess.Popen([godot, "--path", project])

    client = AssistantClient(host=args.host, port=args.port)
    try:
        print("Connecting to %s:%d..." % (args.host, args.port))
        client.connect()
        print("Connected!\n")

        runner = TestRunner(client, skip_save=args.skip_save)
        success = runner.run_all()

        # 9.3 Step 6: Quit
        print("\n[6. Quit]")
        print("  Sending quit with force...")
        client.call("quit", {"force": True})
    except Exception as e:
        print("\nERROR: %s" % e)
        success = False
    finally:
        client.close()
        if godot_proc:
            godot_proc.wait(timeout=10)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
