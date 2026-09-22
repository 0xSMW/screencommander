# ScreenCommander performance A/B

Freeze a baseline checkout before editing and build both versions with `swift build -c release` using the same toolchain. No installed executable needs to be replaced.

```sh
python3 bench/live_ab.py --baseline /absolute/baseline/.build/release/screencommander --candidate /absolute/candidate/.build/release/screencommander --fixture /absolute/candidate/bench/AXFixture.swift --output /absolute/candidate/bench/results/live-ab.json
SCREENCOMMANDER_PERF_AB=1 swift test -c release --filter 'PerformanceTests'
```

The live harness creates a dedicated AppKit fixture containing 520 buttons, sparse controls and a large text document. It targets only this process, alternates/randomizes paired variant order, warms both servers, and reports raw samples plus p50/p95 and wire bytes. Accessibility and Screen Recording must already be granted. It restores focus when the fixture remains frontmost and shuts down its own processes. It does not act on personal documents or replace the installed application.

Full/role/text reads must preserve the relevant record fields, clicks must increment the fixture counter, screenshot dimensions must match, and applying snapshot deltas must reconstruct the full observation. Budget-limited reads are explicitly incomplete; their timing is not an equal-work speedup. Snapshot deltas still read AX afresh: their primary gain is smaller responses. Optional post-action observation removes a tool round trip but does not wait for asynchronous UI settling.

The release test benchmarks compare the old/new screenshot compression and metadata path, observer hydration, snapshot wire payload, and synthetic AX work counts. Mock-only timings do not model cross-process AX latency. `SCREENCOMMANDER_PERF_APP_PID` optionally targets an already-running dedicated fixture for real observer hydration measurements.

Run correctness checks before measurements, save complete raw evidence, and report regressions as well as gains. Different toolchains, apps, tree shapes, animation and machine load affect timings; these fixtures establish bounded evidence rather than universal speedup claims.

## Image capture A/B

`capture_ab.py` uses a separate disposable window with deterministic pixels. Compare the previously optimized binary (including the encode-once change) against the capture candidate:

```sh
python3 bench/capture_ab.py --baseline /absolute/frozen/screencommander --candidate /absolute/candidate/.build/release/screencommander --fixture /absolute/candidate/bench/CaptureFixture.swift --output /absolute/existing/capture-results/capture-ab.json
SCREENCOMMANDER_PERF_AB=1 swift test -c release --filter TTLCacheTests
```

The default PNG run measures 15 paired samples after three warmups for persistent sessions, expired enumeration caches, and first captures in new servers. Initialization is reported separately. Pixel checks run outside timing. Freshness checks change the fixture within the cache lifetime and verify the candidate against current window geometry and fresh reference captures. Use `--format jpeg` for the same-format JPEG control, and `--scenarios warm,freshness,resize` for a shorter acceptance run. The image probe uses ImageIO to compare decoded pixels at native resolution; no downsampling or image-frame cache is enabled.

The gated cache benchmark compares the legacy and candidate caches at the same two-second TTL. Its fetch counts establish coalescing under concurrent misses; its scheduling/gate wall time does not measure ScreenCaptureKit performance. Results from this second phase live separately in `bench/capture-results/`.
