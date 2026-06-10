#!/usr/bin/env python3
"""Orbit accuracy test: compares simulator body positions against JPL Horizons.

Verifies that table-built orbits (IVTableOrbitBuilder) place bodies where the
real solar system has them. Reference state vectors below were fetched from the
JPL Horizons API (EPHEM_TYPE=VECTORS, REF_PLANE=ECLIPTIC, REF_SYSTEM=J2000,
position relative to parent body center, km) so the test runs offline and is
reproducible.

The simulator is queried via the Assistant TCP server's `get_body_position`
with explicit `time` (TT J2000 seconds), which returns the parent-relative
position in the J2000 ecliptic basis — directly comparable to the Horizons
vectors after unit scaling.

Pass criterion is the 3D angular separation (parent-centered) between the sim
and Horizons vectors. Mean-element models legitimately diverge from precise
ephemerides by up to a few degrees (e.g., Earth's Moon), so tolerances are
per-body and generous; the test exists to catch gross propagation errors
(tens of degrees), not to certify ephemeris-grade accuracy.

Usage:
    python orbit_accuracy_test.py                 # game already running
    python orbit_accuracy_test.py --launch        # start Godot, test, quit
    python orbit_accuracy_test.py --bodies MOON_MOON MOON_IO
"""

import argparse
import math
import os
import re
import sys

from assistant_test import AssistantClient, GodotLauncher

EPOCH_JD = 2451545.0  # J2000
DAY_SECONDS = 86400.0

# Reference geometric state vectors from JPL Horizons (fetched 2026-06-10).
# {sim_body_name: {jd_tdb: (x, y, z) km, parent-relative, J2000 ecliptic}}
# JD 2455197.5008 = 2010-01-01 00:00 UTC; JD 2461041.5008 = 2026-01-01 00:00 UTC
# (+69 s to TDB). PLANET_EARTH is Horizons target 3 (Earth-Moon barycenter)
# relative to Sun body center, matching the sim's Earth (really EMB, per
# ivoyager_core/tables/README.md).
HORIZONS_REFERENCE = {
    "MOON_MOON": {
        2455197.5008: (-81449.6377866637, 349985.255288196, 4527.648506677273),
        2461041.5008: (144256.3063128213, 329424.9144062588, 31753.36173943117),
    },
    "MOON_PHOBOS": {
        2455197.5008: (2027.623873983167, -8934.59840573588, -1709.593666445981),
        2461041.5008: (-2501.467445345318, -8873.064551518773, 568.5440027551394),
    },
    "MOON_DEIMOS": {
        2455197.5008: (20430.78407333292, 6292.459661865355, -9643.59012041349),
        2461041.5008: (10789.93843078174, 20547.98819081778, -3379.809756155939),
    },
    "MOON_IO": {
        2455197.5008: (-313469.5605968889, -279184.2400323509, -14283.65151005186),
        2461041.5008: (371755.9968228891, -200243.7062162734, -1923.426365171981),
    },
    "MOON_EUROPA": {
        2455197.5008: (477663.7495471425, 461949.558588819, 21698.33658857286),
        2461041.5008: (83486.37285609105, -669404.5533818398, -19066.81171297032),
    },
    "MOON_TITAN": {
        2455197.5008: (-1181620.738719771, 417307.1322239508, -98468.05146998086),
        2461041.5008: (1111984.186449667, -403852.7117837187, 97602.53414285951),
    },
    "MOON_TRITON": {
        2455197.5008: (191761.4799203961, -131921.04051656, -267721.6963287458),
        2461041.5008: (-284443.5263399122, -29769.0561211805, 209909.5303530779),
    },
    "MOON_CHARON": {
        2455197.5008: (6643.063838694253, -4001.0395704654, -17996.1454479484),
        2461041.5008: (10154.73910679368, 596.316779897993, -16747.80433650185),
    },
    "PLANET_EARTH": {
        2455197.5008: (-26334934.63766209, 144727923.5274948, -3218.775398470461),
        2461041.5008: (-26072444.65802734, 144778303.5216888, -8507.011610202491),
    },
}

# Angular separation tolerance (degrees). Mean-element models drift from the
# real (perturbed) bodies; values below allow known model divergence plus
# margin, while staying far below gross-error scale (tens to >100 degrees).
# Earth's Moon is the most perturbed orbit in the solar system; Phobos has had
# 76 years of tidal secular acceleration since its 1950 table epoch.
ANGLE_TOLERANCE_DEG = {
    "MOON_MOON": 5.0,
    "MOON_PHOBOS": 8.0,
    "PLANET_EARTH": 1.0,
}
DEFAULT_ANGLE_TOLERANCE_DEG = 3.0

RADIUS_RATIO_TOLERANCE = 0.10  # |sim|/|ref| within +/-10%


def find_godot_executable(project_dir):
    """Newest Godot console exe in the project's parent dir matching the
    major version pinned by project.godot config/features."""
    config_path = os.path.join(project_dir, "project.godot")
    major = None
    try:
        with open(config_path, encoding="utf-8") as config_file:
            match = re.search(r'config/features=PackedStringArray\("(\d+\.\d+)"',
                              config_file.read())
            if match:
                major = match.group(1)
    except OSError:
        pass

    parent_dir = os.path.dirname(os.path.abspath(project_dir))
    candidates = []
    for filename in os.listdir(parent_dir):
        match = re.match(r"Godot_v(\d+\.\d+(?:\.\d+)?)-?(\w*)_win64_console\.exe",
                         filename)
        if not match:
            continue
        version, stage = match.group(1), match.group(2)
        if major and not version.startswith(major):
            continue
        stage_rank = {"dev": 0, "beta": 1, "rc": 2, "stable": 3}
        stage_match = re.match(r"(dev|beta|rc|stable)(\d*)", stage)
        if stage_match:
            rank = stage_rank[stage_match.group(1)]
            iteration = int(stage_match.group(2) or 0)
        else:
            rank, iteration = 3, 0
        version_key = tuple(int(p) for p in version.split("."))
        candidates.append((version_key, rank, iteration,
                           os.path.join(parent_dir, filename)))
    if not candidates:
        return None
    candidates.sort()
    return candidates[-1][3]


def angle_between_deg(a, b):
    dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    norm_a = math.sqrt(sum(c * c for c in a))
    norm_b = math.sqrt(sum(c * c for c in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 180.0
    cos_angle = max(-1.0, min(1.0, dot / (norm_a * norm_b)))
    return math.degrees(math.acos(cos_angle))


def ecliptic_lon_lat_deg(v):
    lon = math.degrees(math.atan2(v[1], v[0])) % 360.0
    radius = math.sqrt(sum(c * c for c in v))
    lat = math.degrees(math.asin(v[2] / radius)) if radius else 0.0
    return lon, lat


def run_tests(client, body_filter=None):
    failures = []
    print(f"\n{'body':14s} {'jd_tdb':>12s} {'angle':>8s} {'dlon':>8s} "
          f"{'r_ratio':>8s} {'tol':>5s}  result")
    print("-" * 70)

    for body_name, references in HORIZONS_REFERENCE.items():
        if body_filter and body_name not in body_filter:
            continue
        tolerance = ANGLE_TOLERANCE_DEG.get(body_name, DEFAULT_ANGLE_TOLERANCE_DEG)
        for jd_tdb, ref_vector in references.items():
            time_seconds = (jd_tdb - EPOCH_JD) * DAY_SECONDS
            response = client.call("get_body_position",
                                   {"name": body_name, "time": time_seconds})
            if "error" in response:
                failures.append(f"{body_name} @ {jd_tdb}: {response['error']}")
                print(f"{body_name:14s} {jd_tdb:12.4f}  ERROR: {response['error']}")
                continue
            sim_vector = response["result"]["position"]

            angle = angle_between_deg(sim_vector, ref_vector)
            sim_lon, _sim_lat = ecliptic_lon_lat_deg(sim_vector)
            ref_lon, _ref_lat = ecliptic_lon_lat_deg(ref_vector)
            delta_lon = (sim_lon - ref_lon + 180.0) % 360.0 - 180.0
            sim_radius = math.sqrt(sum(c * c for c in sim_vector))
            ref_radius = math.sqrt(sum(c * c for c in ref_vector))
            radius_ratio = sim_radius / ref_radius if ref_radius else float("inf")

            ok = angle <= tolerance and abs(radius_ratio - 1.0) <= RADIUS_RATIO_TOLERANCE
            if not ok:
                failures.append(
                    f"{body_name} @ {jd_tdb}: angle {angle:.2f} deg "
                    f"(tol {tolerance}), r_ratio {radius_ratio:.3f}")
            print(f"{body_name:14s} {jd_tdb:12.4f} {angle:7.2f}° {delta_lon:+7.2f}° "
                  f"{radius_ratio:8.3f} {tolerance:4.1f}°  {'PASS' if ok else 'FAIL'}")

    return failures


def main():
    parser = argparse.ArgumentParser(
        description="Compare sim body positions against JPL Horizons reference vectors")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=29071)
    parser.add_argument("--launch", action="store_true",
                        help="Launch Godot before testing, quit it after")
    parser.add_argument("--godot", default=None, help="Path to Godot console executable")
    parser.add_argument("--project", default=".", help="Path to project directory")
    parser.add_argument("--bodies", nargs="*", default=None,
                        help="Subset of body names to test")
    args = parser.parse_args()

    launcher = None
    if args.launch:
        godot = args.godot or find_godot_executable(args.project)
        if not godot:
            print("No Godot console executable found; use --godot PATH")
            sys.exit(2)
        print(f"Launching: {godot} --path {args.project}")
        launcher = GodotLauncher(godot, args.project)
        launcher.start()

    client = AssistantClient(host=args.host, port=args.port)
    success = False
    try:
        print(f"Connecting to {args.host}:{args.port}...")
        client.connect()

        # get_body_position is sim-gated; wait for readiness via retry on error 4
        import time as time_module
        for _ in range(60):
            response = client.call("get_body_position",
                                   {"name": "PLANET_EARTH", "time": 0.0})
            if "result" in response:
                break
            time_module.sleep(1.0)

        failures = run_tests(client, args.bodies)
        success = not failures
        if failures:
            print(f"\n{len(failures)} FAILURE(S):")
            for failure in failures:
                print(f"  - {failure}")
        else:
            print("\nAll orbit accuracy checks passed.")
    except Exception as exc:
        print(f"\nERROR: {exc}")
    finally:
        if launcher:
            try:
                client.call("quit", {"force": True})
            except Exception:
                pass
            client.close()
            launcher.shutdown_and_report()
            if launcher.leaks:
                success = False
        else:
            client.close()

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
