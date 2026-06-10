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
        # Far dates (years 2500, 2900) exercise the planet mean-anomaly rate over
        # centuries, where dM/dt vs dL/dt confusion would compound (see issue #7
        # follow-up). PLANET_EARTH is the Earth-Moon barycenter (Horizons "3").
        2634166.5000: (-9041217.862812703, 146898746.2799278, -164530.5818493664),
        2780263.5000: (5541806.054948838, 147166751.8044562, -298946.693286702),
    },
    "PLANET_MERCURY": {
        2461041.5008: (-32191355.24063677, -61217992.66352803, -2050305.853280626),
        2634166.5000: (-27488801.68864006, -63734843.21278827, -2760201.628164567),
        2780263.5000: (-58136920.16018341, -3577463.459980177, 4904048.76532228),
    },
    "PLANET_VENUS": {
        2461041.5008: (13298233.50592687, -107973828.247725, -2250692.566886865),
        2634166.5000: (9588695.625431497, 107289264.7474756, 1064453.492698818),
        2780263.5000: (-94936518.42365083, 50186383.1021242, 6210789.550433051),
    },
    "PLANET_MARS": {
        2461041.5008: (50951684.2477811, -207492004.8715962, -5597567.504223526),
        2634166.5000: (62642252.40850581, -203876084.9227972, -5772549.557795018),
        2780263.5000: (-246472740.1627341, 33458657.68373083, 6279954.345535329),
    },
}

# Far-date planet checks (years 2500, 2900) only hold for the linear-element
# JPL model (IVRealPlanetOrbit), which a project enables via
# IVTableOrbitBuilder.use_real_planet_orbits. Projects that don't need that
# precision (e.g. games) build planets as plain IVOrbit instances — accurate
# near J2000 but drifting over centuries. The runner skips these checks (rather
# than failing them) when a planet's reported orbit_class isn't IVRealPlanetOrbit.
FAR_PLANET_JDS = frozenset({2634166.5000, 2780263.5000})
REAL_PLANET_ORBIT_CLASS = "IVRealPlanetOrbit"

# Angular separation tolerance (degrees). Mean-element models drift from the
# real (perturbed) bodies; values below allow known model divergence plus
# margin, while staying far below gross-error scale (tens to >100 degrees).
# Earth's Moon is the most perturbed orbit in the solar system; Phobos has had
# 76 years of tidal secular acceleration since its 1950 table epoch.
ANGLE_TOLERANCE_DEG = {
    "MOON_MOON": 5.0,
    "MOON_PHOBOS": 8.0,
    # Planets use the linear-element JPL model (IVRealPlanetOrbit), good to well
    # under 1 deg across the 3000 BC - 3000 AD validity range once the mean
    # anomaly advances at dM/dt (not dL/dt). 1 deg catches the rate bug at the
    # far test dates while passing comfortably when correct.
    "PLANET_MERCURY": 1.0,
    "PLANET_VENUS": 1.0,
    "PLANET_EARTH": 1.0,
    "PLANET_MARS": 1.0,
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


def get_present_bodies(client):
    """Return the set of body names the project actually loaded, or None if the
    list_bodies capability is unavailable (then presence isn't gated)."""
    response = client.call("list_bodies", {"filter": "all"})
    if "error" in response:
        return None
    return set(response.get("result", {}).get("bodies", []))


def get_orbit_class(client, body_name, cache):
    """Report a body's orbit model class (e.g. 'IVRealPlanetOrbit'), cached.
    Falls back to 'IVOrbit' if the field is absent (older plugin) so far-date
    planet checks degrade to skipped rather than asserted."""
    if body_name in cache:
        return cache[body_name]
    response = client.call("get_body_orbit", {"name": body_name})
    orbit_class = response.get("result", {}).get("orbit_class", "IVOrbit")
    cache[body_name] = orbit_class
    return orbit_class


def run_tests(client, body_filter=None):
    failures = []
    skips = []
    present_bodies = get_present_bodies(client)
    orbit_class_cache = {}
    print(f"\n{'body':14s} {'jd_tdb':>12s} {'angle':>8s} {'dlon':>8s} "
          f"{'r_ratio':>8s} {'tol':>5s}  result")
    print("-" * 70)

    for body_name, references in HORIZONS_REFERENCE.items():
        if body_filter and body_name not in body_filter:
            continue
        # Skip bodies this project doesn't load (different/smaller body set) so
        # the runner stays useful across projects rather than reporting failures.
        if present_bodies is not None and body_name not in present_bodies:
            skips.append(f"{body_name}: not loaded in this project")
            print(f"{body_name:14s} {'(all dates)':>12s}  SKIP: body not loaded")
            continue
        tolerance = ANGLE_TOLERANCE_DEG.get(body_name, DEFAULT_ANGLE_TOLERANCE_DEG)
        for jd_tdb, ref_vector in references.items():
            # Far-date planet checks require the IVRealPlanetOrbit model. Skip
            # (don't fail) when the project builds plain Keplerian planet orbits.
            if jd_tdb in FAR_PLANET_JDS and body_name.startswith("PLANET_"):
                orbit_class = get_orbit_class(client, body_name, orbit_class_cache)
                if orbit_class != REAL_PLANET_ORBIT_CLASS:
                    skips.append(f"{body_name} @ {jd_tdb}: far-date check needs "
                                 f"{REAL_PLANET_ORBIT_CLASS}, project uses {orbit_class}")
                    print(f"{body_name:14s} {jd_tdb:12.4f}  SKIP: "
                          f"needs {REAL_PLANET_ORBIT_CLASS} (got {orbit_class})")
                    continue

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

    return failures, skips


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

        # Sim-gated methods return error 4 until the readiness gate opens. Probe
        # list_bodies (no specific body required) until it returns a result.
        import time as time_module
        for _ in range(60):
            response = client.call("list_bodies", {"filter": "all"})
            if "result" in response:
                break
            time_module.sleep(1.0)

        failures, skips = run_tests(client, args.bodies)
        success = not failures
        if skips:
            print(f"\n{len(skips)} skipped:")
            for skip in skips:
                print(f"  - {skip}")
        if failures:
            print(f"\n{len(failures)} FAILURE(S):")
            for failure in failures:
                print(f"  - {failure}")
        else:
            checked = "all applicable" if skips else "all"
            print(f"\nOrbit accuracy: {checked} checks passed.")
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
