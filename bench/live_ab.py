#!/usr/bin/env python3
"""Live, paired MCP A/B measurement against a disposable AppKit AX fixture.

Example:
  python3 bench/live_ab.py --baseline /absolute/baseline/screencommander \
      --candidate /absolute/optimized/screencommander \
      --fixture /absolute/repo/bench/AXFixture.swift --output /absolute/ab.json

Only the fixture's counter is clicked. Both serve processes and the fixture are
terminated in finally; no macOS privacy grant is requested by this harness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import selectors
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import traceback


class BenchError(RuntimeError):
    pass


def existing_absolute(value, executable=False):
    path = Path(value)
    if not path.is_absolute() or not path.is_file():
        raise argparse.ArgumentTypeError(f"existing absolute file required: {value}")
    if executable and not os.access(path, os.X_OK):
        raise argparse.ArgumentTypeError(f"executable required: {value}")
    return path


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def percentile(values, fraction):
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    low = int(index)
    return ordered[low] + (ordered[min(low + 1, len(ordered) - 1)] - ordered[low]) * (index - low)


def describe(samples):
    return {
        "n": len(samples),
        "p50Ms": round(statistics.median(s["durationMs"] for s in samples), 3),
        "p95Ms": round(percentile([s["durationMs"] for s in samples], .95), 3),
        "p50WireBytes": round(statistics.median(s["wireBytes"] for s in samples)),
        "p95WireBytes": round(percentile([s["wireBytes"] for s in samples], .95)),
    }


class LineProcess:
    def __init__(self, command, name):
        self.name = name
        self.stderr = tempfile.TemporaryFile(mode="w+b")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, start_new_session=True, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()

    def line(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            index = self.buffer.find(b"\n")
            if index >= 0:
                line = bytes(self.buffer[:index + 1])
                del self.buffer[:index + 1]
                return line
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchError(f"{self.name} response timed out after {timeout}s")
            if not self.selector.select(remaining):
                continue
            chunk = os.read(self.process.stdout.fileno(), 1024 * 1024)
            if not chunk:
                raise BenchError(f"{self.name} exited before response (code {self.process.poll()}): {self.error_tail()}")
            self.buffer.extend(chunk)

    def error_tail(self):
        self.stderr.flush()
        self.stderr.seek(0, os.SEEK_END)
        end = self.stderr.tell()
        self.stderr.seek(max(0, end - 1500))
        return self.stderr.read().decode("utf-8", "replace")

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()  # serve exits when stdin reaches EOF
                self.process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        self.selector.close()
        self.process.stdout.close()
        self.stderr.close()


class MCP(LineProcess):
    def __init__(self, binary, name, timeout):
        super().__init__([str(binary), "serve", "--mcp"], name)
        self.next_id = 0
        self.timeout = timeout

    def start(self):
        self.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "screencommander-live-ab", "version": "1"},
        })

    def request(self, method, params):
        self.next_id += 1
        identifier = self.next_id
        wire = json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method,
                           "params": params}, separators=(",", ":")).encode() + b"\n"
        start = time.perf_counter_ns()
        try:
            self.process.stdin.write(wire)
            self.process.stdin.flush()
        except BrokenPipeError as exc:
            raise BenchError(f"{self.name} pipe closed: {self.error_tail()}") from exc
        response_wire = self.line(self.timeout)
        duration_ms = (time.perf_counter_ns() - start) / 1_000_000
        response = json.loads(response_wire)
        if response.get("id") != identifier:
            raise BenchError(f"{self.name}: unexpected JSON-RPC response id {response.get('id')}")
        if "error" in response:
            raise BenchError(f"{self.name} {method}: {response['error']}")
        result = response.get("result", {})
        if result.get("isError") or result.get("structuredContent", {}).get("status") == "error":
            raise BenchError(f"{self.name} {method}: {result.get('structuredContent')}")
        return result, {"durationMs": round(duration_ms, 3), "wireBytes": len(response_wire)}

    def tool(self, name, arguments):
        wrapper, sample = self.request("tools/call", {"name": name, "arguments": arguments})
        envelope = wrapper.get("structuredContent", {})
        if envelope.get("status") != "ok":
            raise BenchError(f"{self.name} {name}: missing successful envelope: {envelope}")
        return envelope.get("result", {}), sample


def elements(server, pid, **options):
    return server.tool("elements", {"app": str(pid), "maxElements": 2000, **options})


def records(result):
    return result.get("elements", [])


def projection(records_):
    # Compare semantic records, not transport metadata or diagnostics.
    return [{key: record.get(key) for key in
             ("id", "role", "subrole", "title", "value", "valueTruncated", "description",
              "enabled", "focused", "actions", "boundsPoints", "boundsPixels")}
            for record in records_]


def role_projection(result):
    return projection(records(result))


def counter(result):
    for record in records(result):
        for value in (record.get("value"), record.get("title"), record.get("description")):
            match = re.search(r"Fixture count:\s*(\d+)", str(value))
            if match:
                return int(match.group(1))
    raise BenchError("fixture counter missing from full AX result")


def button_id(result):
    hits = [record["id"] for record in records(result)
            if record.get("role") == "AXButton" and
            (record.get("title") == "Increment fixture counter" or
             record.get("description") == "Increment fixture counter")]
    if len(hits) != 1:
        raise BenchError(f"expected one fixture action button; found {len(hits)}")
    return hits[0]


def paired(name, runs, baseline_call, candidate_call, output, rng):
    raw = {"baseline": [], "candidate": []}
    output[name] = {"samples": raw, "equivalent": name in ("full", "role", "text")}
    for index in range(runs[0] + runs[1]):
        order = ["baseline", "candidate"] if index % 2 == 0 else ["candidate", "baseline"]
        if rng.randrange(2):
            order.reverse()
        # Balance the randomization as pairs to keep first-run effects symmetric.
        if index % 2:
            order = list(reversed(previous_order))
        previous_order = order
        round_results = {}
        for variant in order:
            result, sample = (baseline_call if variant == "baseline" else candidate_call)()
            round_results[variant] = result
            if index >= runs[0]:
                raw[variant].append({"pair": index - runs[0], "order": order,
                                     "durationMs": sample["durationMs"], "wireBytes": sample["wireBytes"]})
        if name in ("full", "role", "text"):
            a, b = round_results["baseline"], round_results["candidate"]
            if name == "text":
                if a.get("text") != b.get("text"):
                    raise BenchError("text profile differs from baseline complete text rendering")
            elif role_projection(a) != role_projection(b):
                raise BenchError(f"{name} returned different semantic AX records")
        elif name == "screenshot":
            a_image = round_results["baseline"].get("metadata", {}).get("imageSizePixels")
            b_image = round_results["candidate"].get("metadata", {}).get("imageSizePixels")
            if not a_image or a_image != b_image:
                raise BenchError(f"screenshot dimensions differ: {a_image}, {b_image}")
    output[name]["summary"] = {variant: describe(values) for variant, values in raw.items()}
    if name == "screenshot":
        output[name]["dimensionsEquivalent"] = True


def counter_normalized(result):
    normalized = projection(records(result))
    for record in normalized:
        for key in ("title", "value", "description"):
            if isinstance(record.get(key), str):
                record[key] = re.sub(r"Fixture count:\s*\d+", "Fixture count: <n>", record[key])
    return normalized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=lambda x: existing_absolute(x, True))
    parser.add_argument("--candidate", required=True, type=lambda x: existing_absolute(x, True))
    parser.add_argument("--fixture", required=True, type=existing_absolute, help="absolute path to AXFixture.swift")
    parser.add_argument("--output", required=True, type=Path, help="existing-parent absolute JSON output path")
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument("--timeout", type=float, default=30, help="seconds per MCP response")
    parser.add_argument("--seed", type=int, default=20260922)
    args = parser.parse_args()
    if not args.output.is_absolute() or not args.output.parent.is_dir():
        parser.error("--output needs an absolute path with an existing parent directory")
    if args.warmups < 3 or args.samples < 15 or args.timeout <= 0:
        parser.error("at least 3 warmups, 15 samples, and a positive timeout are required")

    report = {
        "status": "partial", "fixture": str(args.fixture), "baseline": str(args.baseline),
        "candidate": str(args.candidate), "warmupsPerVariant": args.warmups,
        "samplesPerVariant": args.samples, "seed": args.seed, "scenarios": {},
        "host": platform.platform(), "sha256": {
            "fixtureSource": digest(args.fixture), "baselineBinary": digest(args.baseline),
            "candidateBinary": digest(args.candidate)},
        "notes": ["Wall-clock MCP request/response includes JSON encoding and IPC, on warm serve sessions.",
                  "Snapshot deltas and maxVisited budgets are different work from full traversal; compare result semantics and wire bytes separately.",
                  "No permission grants are attempted; doctor preflight must report both permissions already granted."],
    }
    processes = []
    rng = random.Random(args.seed)
    try:
        with tempfile.TemporaryDirectory(prefix="screencommander-live-ab-") as temp:
            compiled = Path(temp) / "ax-fixture"
            compile_result = subprocess.run(["swiftc", "-framework", "Cocoa", str(args.fixture),
                                             "-o", str(compiled)], capture_output=True, text=True, timeout=120)
            if compile_result.returncode:
                raise BenchError(f"fixture compilation failed: {compile_result.stderr[-2500:]}")
            fixture = LineProcess([str(compiled)], "fixture")
            processes.append(fixture)
            ready = fixture.line(15).decode("utf-8", "replace").strip()
            if not ready.startswith("READY "):
                raise BenchError(f"fixture readiness unexpected: {ready}")
            fixture_info = json.loads(ready[6:])
            pid = fixture_info["pid"]
            report["fixtureInfo"] = fixture_info
            if fixture_info["controls"] < 500 or fixture_info["documentCharacters"] < 100_000:
                raise BenchError("fixture does not meet benchmark size requirements")

            a = MCP(args.baseline, "baseline", args.timeout)
            processes.append(a)
            a.start()
            b = MCP(args.candidate, "candidate", args.timeout)
            processes.append(b)
            b.start()
            for server in (a, b):
                health, _ = server.tool("doctor", {})
                permissions = health.get("permissions", {})
                report.setdefault("permissionPreflight", {})[server.name] = permissions
                if not permissions.get("screenRecordingGranted") or not permissions.get("accessibilityGranted"):
                    raise BenchError(f"{server.name}: existing Screen Recording and Accessibility grants required")

            a_full = lambda: elements(a, pid)
            b_full = lambda: elements(b, pid)
            initial, _ = a_full()
            if initial.get("truncated") or len(records(initial)) < 500:
                raise BenchError(f"full fixture tree too small/truncated: {len(records(initial))} records")
            action_id = button_id(initial)
            report["observedElements"] = len(records(initial))
            paired("full", (args.warmups, args.samples), a_full, b_full, report["scenarios"], rng)
            paired("role", (args.warmups, args.samples),
                   lambda: elements(a, pid, roles=["AXCheckBox"]),
                   lambda: elements(b, pid, roles=["AXCheckBox"]), report["scenarios"], rng)
            paired("text", (args.warmups, args.samples),
                   lambda: elements(a, pid, text=True),
                   lambda: elements(b, pid, profile="text", text=True), report["scenarios"], rng)

            budget_samples = []
            for index in range(args.warmups + args.samples):
                budget, sample = elements(b, pid, maxVisited=90)
                visited = budget.get("visitedCount", budget.get("visited"))
                if visited is None or visited > 90 or not budget.get("truncated"):
                    raise BenchError(f"budget read did not report bounded incomplete traversal: visited={visited}")
                if index >= args.warmups:
                    budget_samples.append({"pair": index - args.warmups, **sample,
                                           "visited": visited, "returned": len(records(budget))})
            report["scenarios"]["budget"] = {"samples": {"candidate": budget_samples},
                "summary": {"candidate": describe(budget_samples)}, "equivalent": False,
                "semantics": "maxVisited=90; incomplete tree; compare visited and returned counts, not full-tree equality"}

            windows, _ = a.tool("windows", {"app": str(pid)})
            targets = [w for w in windows.get("windows", []) if w.get("pid") == pid and
                       w.get("title") == "ScreenCommander AX Benchmark Fixture"]
            if len(targets) != 1:
                raise BenchError(f"fixture window resolution ambiguous: {targets}")
            window_id = str(targets[0]["windowID"])
            paired("screenshot", (args.warmups, args.samples),
                   lambda: a.tool("screenshot", {"window": window_id, "path": str(Path(temp) / "a.png"),
                                                  "updateLastMetadata": False}),
                   lambda: b.tool("screenshot", {"window": window_id, "path": str(Path(temp) / "b.png"),
                                                  "updateLastMetadata": False}),
                   report["scenarios"], rng)

            initial_count = counter(initial)
            action_arguments = {"app": str(pid), "elementId": action_id, "via": "ax",
                                "noCursor": True, "strict": True}
            paired("action", (args.warmups, args.samples),
                   lambda: a.tool("click", action_arguments),
                   lambda: b.tool("click", action_arguments), report["scenarios"], rng)
            after_actions, _ = a_full()
            expected = initial_count + 2 * (args.warmups + args.samples)
            observed = counter(after_actions)
            if observed != expected:
                raise BenchError(f"AX action outcome: fixture count {observed}, expected {expected}")
            report["scenarios"]["action"]["counterBeforeAfter"] = [initial_count, observed]

            post_raw = {"baselineTwoCalls": [], "candidateFused": []}
            report["scenarios"]["postObserve"] = {
                "samples": post_raw, "equivalent": True,
                "semantics": "A direct AX click followed by a full elements request; B direct AX click with a full postObserve result. Counter is expected to increment once per click.",
            }
            next_count = observed
            for index in range(args.warmups + args.samples):
                order = ["baselineTwoCalls", "candidateFused"] if index % 2 == 0 else ["candidateFused", "baselineTwoCalls"]
                if index % 2:
                    order = list(reversed(previous_post_order))
                elif rng.randrange(2):
                    order.reverse()
                previous_post_order = order
                observations = {}
                for variant in order:
                    if variant == "baselineTwoCalls":
                        _, click_sample = a.tool("click", action_arguments)
                        observation, read_sample = a_full()
                        sample = {"durationMs": round(click_sample["durationMs"] + read_sample["durationMs"], 3),
                                  "wireBytes": click_sample["wireBytes"] + read_sample["wireBytes"]}
                    else:
                        result, sample = b.tool("click", {**action_arguments, "postObserve": {
                            "app": str(pid), "maxElements": 2000, "maxVisited": 10000,
                            "timeoutMs": 5000, "profile": "full"}})
                        if result.get("observationError"):
                            raise BenchError(f"postObserve read failed: {result['observationError']}")
                        observation = result.get("observation")
                        if not isinstance(observation, dict):
                            raise BenchError("postObserve did not attach an AX observation")
                    next_count += 1
                    if counter(observation) != next_count:
                        raise BenchError(f"postObserve counter mismatch after {variant}: expected {next_count}")
                    observations[variant] = observation
                    if index >= args.warmups:
                        post_raw[variant].append({"pair": index - args.warmups, "order": order, **sample})
                if counter_normalized(observations["baselineTwoCalls"]) != counter_normalized(observations["candidateFused"]):
                    raise BenchError("postObserve differs from same-state baseline projection after ignoring counter number")
            report["scenarios"]["postObserve"]["summary"] = {
                variant: describe(values) for variant, values in post_raw.items()}
            report["scenarios"]["postObserve"]["counterBeforeAfter"] = [observed, next_count]

            # This is a separate B-only delta test: the baseline always returns
            # a complete tree. It is never labeled a like-for-like AX speedup.
            delta_samples, full_samples = [], []
            for index in range(args.warmups + args.samples):
                base, _ = elements(b, pid, snapshot=True)
                snapshot_id = base.get("snapshotId")
                if not snapshot_id or not records(base):
                    raise BenchError("candidate snapshot read lacks snapshotId or complete initial elements")
                b.tool("click", action_arguments)
                if index % 2:
                    delta, delta_sample = elements(b, pid, since=snapshot_id)
                    complete, full_sample = a_full()
                else:
                    complete, full_sample = a_full()
                    delta, delta_sample = elements(b, pid, since=snapshot_id)
                if delta.get("baseSnapshotId") != snapshot_id or not delta.get("snapshotId"):
                    raise BenchError("candidate delta lacks matching baseSnapshotId/new snapshotId")
                if delta.get("resetReason"):
                    raise BenchError(f"candidate snapshot reset instead of delta: {delta['resetReason']}")
                combined = {record["id"]: record for record in records(base)}
                for removed_id in delta.get("removedIds", []):
                    combined.pop(removed_id, None)
                for record in records(delta):
                    combined[record["id"]] = record
                if {r["id"]: r for r in projection(combined.values())} != {
                        r["id"]: r for r in projection(records(complete))}:
                    raise BenchError("reconstructed candidate delta differs from baseline complete AX tree")
                if index >= args.warmups:
                    delta_samples.append({"pair": index - args.warmups, **delta_sample,
                                          "changed": len(records(delta)),
                                          "removed": len(delta.get("removedIds", []))})
                    full_samples.append({"pair": index - args.warmups, **full_sample})
            report["scenarios"]["snapshot"] = {"samples": {"baselineFull": full_samples,
                "candidateDelta": delta_samples}, "summary": {"baselineFull": describe(full_samples),
                "candidateDelta": describe(delta_samples)}, "reconstructionEquivalent": True,
                "equivalent": False,
                "semantics": "B delta after a fixture counter change vs A complete tree on the same state; response byte savings are not AX traversal latency savings"}
            report["status"] = "ok"
    except (BenchError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
        report["error"] = str(exc)
    except KeyboardInterrupt:
        report["error"] = "interrupted"
    except Exception as exc:
        report["error"] = f"unexpected {type(exc).__name__}: {exc}"
        report["traceback"] = traceback.format_exc()
    finally:
        cleanup_errors = []
        for process in reversed(processes):
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
