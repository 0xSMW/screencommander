#!/usr/bin/env python3
"""Paired live MCP window-capture benchmark using only CaptureFixture.swift.

Example:
  python3 bench/capture_ab.py --baseline /absolute/baseline/screencommander \
    --candidate /absolute/current/screencommander \
    --fixture /absolute/repo/bench/CaptureFixture.swift \
    --output /absolute/capture-results/capture-ab.json

Scenarios: warm,cold,ttl,freshness,resize. Use --scenarios to select a subset.
Cold reports server initialize time separately from first-capture response time;
neither is confused with a warm request. PNG is the default. ImageIO decodes
PNG/JPEG into fixed RGBA8 via CapturePixelProbe outside each timed sequence.
"""
import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import time
import traceback

sys.dont_write_bytecode = True
from live_ab import BenchError, LineProcess, MCP, describe, digest, existing_absolute, percentile

SCENARIOS = ("warm", "cold", "ttl", "freshness", "resize")


@contextmanager
def retained_scratch():
    # Keep fixture-only captures and diagnostics for failure review.
    yield tempfile.mkdtemp(prefix="screencommander-capture-ab-")


class CaptureMCP(MCP):
    def __init__(self, binary, name, timeout, scratch):
        super().__init__(binary, name, timeout)
        self.scratch = scratch

    def request(self, method, params):
        description = method + ("/" + str(params.get("name")) if method == "tools/call" else "")
        request_id = self.next_id + 1
        try:
            return super().request(method, params)
        except BenchError as exc:
            if "timed out" not in str(exc):
                raise BenchError(f"{self.name} {description} request {request_id}: {exc}") from exc
            process_id = self.process.pid
            sample_path = self.scratch / f"timeout-{self.name}-{request_id}.sample.txt"
            sample_status = "unavailable"
            if self.process.poll() is None and Path("/usr/bin/sample").is_file():
                try:
                    probe = subprocess.run(["/usr/bin/sample", str(process_id), "1", "-file",
                                            str(sample_path)], capture_output=True, text=True, timeout=8)
                    sample_status = f"exit={probe.returncode} path={sample_path} stderr={probe.stderr[-300:]}"
                except (OSError, subprocess.TimeoutExpired) as diagnostic_error:
                    sample_status = str(diagnostic_error)
            raise BenchError(f"{self.name} {description} request {request_id} timed out; "
                             f"pid={process_id} alive={self.process.poll() is None}; "
                             f"sample={sample_status}; stderrTail={self.error_tail()[-1200:]}") from exc


def pixel_probe(binary, path):
    result = subprocess.run([str(binary), str(path)], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise BenchError(f"pixel probe failed for {path}: {result.stderr[-1200:]}")
    return json.loads(result.stdout)


def assert_marker(image, color):
    r, g, b = image["centerRGB"]
    expected = (r < 10 and g < 10 and b < 10) if color == "black" else (
        (r > 170 and g < 80 and b < 80) if color == "red" else (b > 170 and r < 80 and g < 80))
    if not expected:
        raise BenchError(f"capture center pixel {r,g,b} does not show {color} fixture marker")


def assert_same_image(a_image, b_image, image_format, label="capture"):
    if (a_image["width"], a_image["height"]) != (b_image["width"], b_image["height"]):
        raise BenchError(f"{label}: A/B decoded image dimensions differ: "
                         f"{a_image['width']}x{a_image['height']} vs {b_image['width']}x{b_image['height']}")
    if a_image["rgbaSHA256"] == b_image["rgbaSHA256"]:
        return
    if image_format == "png":
        raise BenchError(f"{label}: A/B PNG pixels differ; "
                         f"baselineRGBA={a_image['rgbaSHA256']} candidateRGBA={b_image['rgbaSHA256']}; "
                         f"centers={a_image['centerRGB']}/{b_image['centerRGB']}")
    # JPEG can differ by a few levels. The marker and 25 spatial samples must match.
    for a_rgb, b_rgb in zip(a_image["sampleRGB"], b_image["sampleRGB"]):
        if any(abs(a - b) > 8 for a, b in zip(a_rgb, b_rgb)):
            raise BenchError(f"{label}: A/B JPEG sampled pixels differ materially: {a_rgb}/{b_rgb}")


def assert_metadata(result, image, window_id):
    metadata = result.get("metadata", {})
    size = metadata.get("imageSizePixels", {})
    bounds = metadata.get("windowBoundsPoints", {})
    scale = metadata.get("pointPixelScale", 0)
    if metadata.get("windowID") != int(window_id) or not bounds or not (scale >= 1):
        raise BenchError(f"invalid window metadata: {metadata}")
    if int(round(size.get("w", -1))) != image["width"] or int(round(size.get("h", -1))) != image["height"]:
        raise BenchError("metadata image size differs from decoded pixels")
    if abs(image["width"] - bounds["w"] * scale) > 2 or abs(image["height"] - bounds["h"] * scale) > 2:
        raise BenchError("pixel dimensions inconsistent with window bounds and point scale")
    return metadata


def fixture_command(fixture, **command):
    wire = json.dumps(command, separators=(",", ":")).encode() + b"\n"
    fixture.process.stdin.write(wire)
    fixture.process.stdin.flush()
    response = json.loads(fixture.line(10))
    if response.get("status") != "ok":
        raise BenchError(f"fixture command failed: {response}")
    return response


def capture(server, window_id, image_format, scratch, label):
    path = scratch / f"{label}.{ 'jpg' if image_format == 'jpeg' else 'png' }"
    try:
        result, sample = server.tool("screenshot", {"window": str(window_id),
            "path": str(path), "format": image_format, "updateLastMetadata": False,
            "includeCursor": False})
    except Exception as exc:
        raise BenchError(f"{label} {server.name} screenshot request: {exc}") from exc
    if not path.is_file():
        raise BenchError(f"capture output missing: {path}")
    metadata = result.get("metadata", {})
    sample["fileBytes"] = path.stat().st_size
    return result, sample, path, metadata


def validate_pair(observations, image_format, probe_binary, window_id, marker, label):
    images = {}
    for variant in ("baseline", "candidate"):
        result, sample, path, _ = observations[variant]
        try:
            image = pixel_probe(probe_binary, path)
            metadata = assert_metadata(result, image, window_id)
            assert_marker(image, marker)
        except Exception as exc:
            raise BenchError(f"{label} {variant} validate {path}: {exc}") from exc
        sample["pixelSHA256"] = image["rgbaSHA256"]
        images[variant] = image
        observations[variant] = (result, sample, path, metadata)
    assert_same_image(images["baseline"], images["candidate"], image_format, label)
    a_meta, b_meta = observations["baseline"][3], observations["candidate"][3]
    for field in ("displayID", "windowID", "windowBoundsPoints", "imageSizePixels", "pointPixelScale"):
        if a_meta.get(field) != b_meta.get(field):
            raise BenchError(f"{label}: A/B {field} metadata differs: {a_meta.get(field)} / {b_meta.get(field)}")


def validate_one(observation, probe_binary, window_id, marker, label):
    result, sample, path, _ = observation
    try:
        image = pixel_probe(probe_binary, path)
        metadata = assert_metadata(result, image, window_id)
        assert_marker(image, marker)
    except Exception as exc:
        raise BenchError(f"{label} validate {path}: {exc}") from exc
    sample["pixelSHA256"] = image["rgbaSHA256"]
    return image, metadata


def assert_fixture_bounds(metadata, fixture_state, label):
    authoritative = fixture_state.get("frameCG")
    if not authoritative:
        raise BenchError(f"fixture did not provide CGWindow bounds for {label}")
    actual = metadata.get("windowBoundsPoints", {})
    if any(abs(actual.get(key, float("inf")) - authoritative[key]) > 2
           for key in ("x", "y", "w", "h")):
        raise BenchError(f"{label} metadata bounds {actual} differ from fixture CG bounds {authoritative}")


def pair_order(index, rng, last):
    if index % 2:
        return list(reversed(last))
    result = ["baseline", "candidate"]
    if rng.randrange(2):
        result.reverse()
    return result


def add_summary(scenario):
    scenario["summary"] = {variant: describe(samples) for variant, samples in scenario["samples"].items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=lambda x: existing_absolute(x, True))
    parser.add_argument("--candidate", required=True, type=lambda x: existing_absolute(x, True))
    parser.add_argument("--fixture", required=True, type=existing_absolute)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--format", choices=("png", "jpeg"), default="png")
    parser.add_argument("--scenarios", default=",".join(SCENARIOS),
                        help="comma-separated subset: " + ",".join(SCENARIOS))
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument("--ttl-wait", type=float, default=2.25)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--seed", type=int, default=20260922)
    args = parser.parse_args()
    selected = tuple(dict.fromkeys(s.strip() for s in args.scenarios.split(",") if s.strip()))
    if not selected or any(s not in SCENARIOS for s in selected):
        parser.error("--scenarios must be a nonempty subset of " + ",".join(SCENARIOS))
    if args.warmups < 3 or args.samples < 15 or args.ttl_wait <= 2 or args.timeout <= 0:
        parser.error("requires at least 3 warmups, 15 samples, TTL wait >2s, positive timeout")
    if not args.output.is_absolute() or not args.output.parent.is_dir():
        parser.error("--output needs an absolute path with an existing parent directory")
    probe_source = Path(__file__).resolve().with_name("CapturePixelProbe.swift")
    if not probe_source.is_file():
        parser.error(f"missing pixel probe source: {probe_source}")

    report = {"status": "partial", "format": args.format, "scenariosSelected": selected,
              "baseline": str(args.baseline), "candidate": str(args.candidate),
              "fixture": str(args.fixture), "warmupsPerVariant": args.warmups,
              "samplesPerVariant": args.samples, "ttlWaitSeconds": args.ttl_wait,
              "seed": args.seed, "sha256": {"baselineBinary": digest(args.baseline),
                "candidateBinary": digest(args.candidate), "fixtureSource": digest(args.fixture),
                "pixelProbeSource": digest(probe_source)},
              "scenarios": {}, "notes": [
                "All captures target one disposable fixture window by CGWindowID; no display or user-app capture.",
                "MCP response duration includes capture, encoding, file write, JSON serialization, and stdio transfer.",
                "Cold initialization, first capture, and combined times are reported separately; warm and expired-TTL sessions remain alive.",
                "ImageIO pixel probing and fixture changes occur outside measured screenshot request time.",
                "For live freshness/geometry checks, the candidate is captured immediately after mutation; baseline oracle is taken after TTL expiry.",
              ]}
    active = []
    rng = random.Random(args.seed)
    try:
        with retained_scratch() as scratch_path:
            scratch = Path(scratch_path)
            report["scratchPath"] = str(scratch)
            binary = scratch / "capture-fixture"
            built = subprocess.run(["swiftc", "-framework", "Cocoa", str(args.fixture), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=120)
            if built.returncode:
                raise BenchError(f"fixture compilation failed: {built.stderr[-2500:]}")
            probe_binary = scratch / "capture-pixel-probe"
            probe_build = subprocess.run(["swiftc", "-framework", "Foundation", "-framework", "ImageIO",
                "-framework", "CoreGraphics", "-framework", "CryptoKit", str(probe_source),
                "-o", str(probe_binary)], capture_output=True, text=True, timeout=120)
            if probe_build.returncode:
                raise BenchError(f"pixel probe compilation failed: {probe_build.stderr[-2500:]}")
            fixture = LineProcess([str(binary)], "fixture")
            active.append(fixture)
            ready = fixture.line(15).decode("utf-8", "replace").strip()
            if not ready.startswith("READY "):
                raise BenchError(f"fixture readiness unexpected: {ready}")
            state = json.loads(ready[6:])
            pid = state["pid"]
            report["fixturePID"] = pid
            report["initialFixtureGeometry"] = state

            servers = {}
            for name, path in (("baseline", args.baseline), ("candidate", args.candidate)):
                server = CaptureMCP(path, name, args.timeout, scratch)
                active.append(server)
                server.start()
                health, _ = server.tool("doctor", {})
                permissions = health.get("permissions", {})
                report.setdefault("permissionPreflight", {})[name] = permissions
                if not permissions.get("screenRecordingGranted"):
                    raise BenchError(f"{name}: Screen Recording permission is not already granted")
                servers[name] = server
            windows, _ = servers["baseline"].tool("windows", {"app": str(pid)})
            matches = [w for w in windows.get("windows", []) if w.get("pid") == pid and
                       w.get("title") == "ScreenCommander Capture Benchmark Fixture"]
            if len(matches) != 1:
                raise BenchError(f"expected one fixture window, found {len(matches)}")
            window_id = matches[0]["windowID"]
            report["fixtureWindowID"] = window_id

            def run_pair(name, index, order, expire=False):
                observations = {}
                for variant in order:
                    if expire:
                        time.sleep(args.ttl_wait)
                    result, sample, path, metadata = capture(servers[variant], window_id, args.format,
                        scratch, f"{name}-{index}-{variant}")
                    observations[variant] = (result, sample, path, metadata)
                return observations

            if "warm" not in selected and ("freshness" in selected or "resize" in selected):
                state = fixture_command(fixture, command="geometry")  # calls displayIfNeeded
                for index in range(3):
                    run_pair("settle-warmup", index,
                             ["baseline", "candidate"] if index % 2 == 0 else ["candidate", "baseline"])
                report["fixtureSettleWarmupPairs"] = 3

            for scenario in ("warm", "ttl"):
                if scenario not in selected:
                    continue
                raw = {"baseline": [], "candidate": []}
                report["scenarios"][scenario] = {"samples": raw, "pixelsEquivalent": True,
                    "semantics": "same fixture window and pixels; TTL wait precedes each call" if scenario == "ttl"
                    else "warm persistent serve sessions, same fixture window and pixels"}
                previous = None
                pending = []
                for index in range(args.warmups + args.samples):
                    order = pair_order(index, rng, previous)
                    previous = order
                    outputs = run_pair(scenario, index, order, expire=scenario == "ttl")
                    pending.append(outputs)
                    if index >= args.warmups:
                        for variant in order:
                            raw[variant].append({"pair": index - args.warmups, "order": order,
                                                 **outputs[variant][1]})
                for index, outputs in enumerate(pending):
                    validate_pair(outputs, args.format, probe_binary, window_id,
                                  state["marker"], f"{scenario} pair {index}")
                add_summary(report["scenarios"][scenario])

            if "cold" in selected:
                raw = {"baseline": [], "candidate": []}
                report["scenarios"]["cold"] = {"samples": raw, "pixelsEquivalent": True,
                    "semantics": "fresh server per capture; startupMs=launch+initialize, durationMs=first screenshot request"}
                previous = None
                pending = []
                for index in range(args.warmups + args.samples):
                    order = pair_order(index, rng, previous)
                    previous = order
                    outputs = {}
                    for variant in order:
                        start = time.perf_counter_ns()
                        print(f"cold pair {index} {variant}: spawn", flush=True)
                        server = CaptureMCP(args.baseline if variant == "baseline" else args.candidate,
                                            variant + "-cold", args.timeout, scratch)
                        active.append(server)
                        print(f"cold pair {index} {variant}: initialize pid={server.process.pid}", flush=True)
                        server.start()
                        print(f"cold pair {index} {variant}: initialize complete", flush=True)
                        startup = (time.perf_counter_ns() - start) / 1_000_000
                        print(f"cold pair {index} {variant}: screenshot", flush=True)
                        result, sample, path, meta = capture(server, window_id, args.format, scratch,
                            f"cold-{index}-{variant}")
                        print(f"cold pair {index} {variant}: screenshot complete {sample['durationMs']}ms", flush=True)
                        sample["startupMs"] = round(startup, 3)
                        sample["startupPlusCaptureMs"] = round(startup + sample["durationMs"], 3)
                        outputs[variant] = (result, sample, path, meta)
                        server.close()
                        active.remove(server)
                        if index >= args.warmups:
                            raw[variant].append({"pair": index - args.warmups, "order": order, **sample})
                    pending.append(outputs)
                for index, outputs in enumerate(pending):
                    validate_pair(outputs, args.format, probe_binary, window_id,
                                  state["marker"], f"cold pair {index}")
                add_summary(report["scenarios"]["cold"])
                for variant, samples in raw.items():
                    report["scenarios"]["cold"]["summary"][variant]["p50StartupMs"] = round(percentile([s["startupMs"] for s in samples], .5), 3)
                    report["scenarios"]["cold"]["summary"][variant]["p95StartupMs"] = round(percentile([s["startupMs"] for s in samples], .95), 3)
                    report["scenarios"]["cold"]["summary"][variant]["p50StartupPlusCaptureMs"] = round(percentile([s["startupPlusCaptureMs"] for s in samples], .5), 3)
                    report["scenarios"]["cold"]["summary"][variant]["p95StartupPlusCaptureMs"] = round(percentile([s["startupPlusCaptureMs"] for s in samples], .95), 3)

            def changed_fixture(label, command):
                # Candidate is the last pre-change capture. No decoding or other
                # slow work occurs before its immediate post-change capture.
                time.sleep(args.ttl_wait)  # force the pre-change pair to fetch current handles
                before = {"baseline": capture(servers["baseline"], window_id, args.format,
                                               scratch, label + "-before-0-baseline")}
                # Only the candidate's clock can bound the age of its cached
                # handles; a slow baseline pre-read must not count against it.
                prewarm_started_at = time.monotonic()
                before["candidate"] = capture(servers["candidate"], window_id, args.format,
                                              scratch, label + "-before-0-candidate")
                candidate_warmed_at = time.monotonic()
                new_state = fixture_command(fixture, **command)
                time.sleep(.2)  # bounded AppKit/WindowServer publication allowance
                # Read WindowServer bounds after publication; the synchronous
                # resize acknowledgment may still contain its previous bounds.
                new_state = fixture_command(fixture, command="geometry")
                candidate_gap = time.monotonic() - candidate_warmed_at
                if candidate_gap >= 2:
                    raise BenchError(f"{label}: candidate cache expired before changed capture ({candidate_gap:.3f}s)")
                immediate_candidate = capture(servers["candidate"], window_id, args.format,
                                              scratch, label + "-candidate-immediate")
                candidate_elapsed = time.monotonic() - candidate_warmed_at
                total_elapsed = time.monotonic() - prewarm_started_at
                if candidate_elapsed >= 2 or total_elapsed >= 2:
                    raise BenchError(f"{label}: post-change capture exceeded TTL; "
                                     f"candidate-only={candidate_elapsed:.3f}s prewarm-start={total_elapsed:.3f}s")
                immediate_baseline = capture(servers["baseline"], window_id, args.format,
                                             scratch, label + "-baseline-immediate")
                time.sleep(args.ttl_wait)
                baseline_oracle = capture(servers["baseline"], window_id, args.format,
                                          scratch, label + "-baseline-oracle")

                # Dynamic checks verify current content and coordinates. Complete
                # frame equality belongs to the static paired timing scenarios:
                # even two baseline frames can vary slightly across the TTL wait.
                for variant in ("baseline", "candidate"):
                    validate_one(before[variant], probe_binary, window_id,
                                 state["marker"], label + " before " + variant)
                candidate_image, candidate_meta = validate_one(immediate_candidate, probe_binary,
                                                                 window_id, new_state["marker"], label + " candidate immediate")
                oracle_image, oracle_meta = validate_one(baseline_oracle, probe_binary,
                                                          window_id, new_state["marker"], label + " baseline post-TTL oracle")
                assert_fixture_bounds(candidate_meta, new_state, label + " candidate")
                assert_fixture_bounds(oracle_meta, new_state, label + " baseline oracle")
                if (candidate_image["width"], candidate_image["height"]) != (oracle_image["width"], oracle_image["height"]):
                    raise BenchError(label + ": candidate dimensions differ from post-TTL oracle")
                baseline_immediate_evidence = {"sample": immediate_baseline[1],
                                               "metadata": immediate_baseline[3]}
                try:
                    baseline_image, baseline_meta = validate_one(immediate_baseline, probe_binary,
                                                                   window_id, new_state["marker"], label + " baseline immediate")
                    baseline_immediate_evidence["markerCurrent"] = True
                    baseline_immediate_evidence["boundsCurrent"] = all(
                        abs(baseline_meta["windowBoundsPoints"][key] - new_state["frameCG"][key]) <= 2
                        for key in ("x", "y", "w", "h"))
                    baseline_immediate_evidence["pixelSHA256"] = baseline_image["rgbaSHA256"]
                except (BenchError, KeyError) as exc:
                    baseline_immediate_evidence["accepted"] = False
                    baseline_immediate_evidence["reason"] = str(exc)
                return new_state, {"candidatePreToPostCaptureSeconds": round(candidate_elapsed, 3),
                    "prewarmStartToPostCaptureSeconds": round(total_elapsed, 3),
                    "candidatePreToPostRequestStartSeconds": round(candidate_gap, 3),
                    "beforeCandidateSHA256": before["candidate"][1]["pixelSHA256"],
                    "beforeCandidateBoundsPoints": before["candidate"][3]["windowBoundsPoints"],
                    "candidateImmediate": {"sample": immediate_candidate[1], "metadata": candidate_meta},
                    "baselineImmediate": baseline_immediate_evidence,
                    "baselineAfterTTL": {"sample": baseline_oracle[1], "metadata": oracle_meta},
                    "authoritativeFixtureBoundsCG": new_state["frameCG"],
                    "candidateGeometryAndMarkerMatchPostTTLOracle": True,
                    "candidatePixelHashMatchesPostTTLOracle": candidate_image["rgbaSHA256"] == oracle_image["rgbaSHA256"],
                    "candidatePixelHashMatchesImmediateBaseline": candidate_image["rgbaSHA256"] == baseline_immediate_evidence.get("pixelSHA256")}

            if "freshness" in selected:
                state, evidence = changed_fixture("marker", {"command": "marker", "color": "black"})
                if evidence["beforeCandidateSHA256"] == evidence["candidateImmediate"]["sample"]["pixelSHA256"]:
                    raise BenchError("candidate retained stale pixels after marker change")
                report["scenarios"]["freshness"] = evidence

            if "resize" in selected:
                state, resized = changed_fixture("resize", {"command": "resize", "width": 780.0, "height": 560.0})
                old_bounds = resized["beforeCandidateBoundsPoints"]
                new_bounds = resized["candidateImmediate"]["metadata"]["windowBoundsPoints"]
                if abs(new_bounds["w"] - 780) > 2 or abs(new_bounds["h"] - 560) > 35:
                    raise BenchError(f"candidate resize metadata has wrong dimensions: {new_bounds}")
                if new_bounds["w"] == old_bounds["w"] and new_bounds["h"] == old_bounds["h"]:
                    raise BenchError("candidate capture dimensions did not change after resize")
                state, moved = changed_fixture("move", {"command": "move", "dx": 35.0, "dy": 25.0})
                moved_bounds = moved["candidateImmediate"]["metadata"]["windowBoundsPoints"]
                if abs(moved_bounds["x"] - new_bounds["x"]) < 10 or abs(moved_bounds["y"] - new_bounds["y"]) < 10:
                    raise BenchError(f"candidate capture origin did not move: {new_bounds} -> {moved_bounds}")
                report["scenarios"]["resize"] = {"resize": resized, "move": moved,
                    "pixelAndCoordinateChecksPassed": True}
            report["status"] = "ok"
    except (BenchError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        report["error"] = str(exc)
    except KeyboardInterrupt:
        report["error"] = "interrupted"
    except Exception as exc:
        report["error"] = f"unexpected {type(exc).__name__}: {exc}"
        report["traceback"] = traceback.format_exc()
    finally:
        cleanup_errors = []
        for process in reversed(active):
            try:
                process.close()
            except Exception as exc:
                cleanup_errors.append(f"{process.name}: {exc}")
        if cleanup_errors:
            report["cleanupErrors"] = cleanup_errors
            report["status"] = "partial"
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"{report['status']}: {args.output}" + (f" ({report['error']})" if "error" in report else ""))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
