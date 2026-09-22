# Image capture performance

Two additional improvements are implemented on `perf/ax-multiturn-ab`: reuse the resolver's display enumeration for window capture, and share concurrent enumeration requests. The baseline already includes the previous encode-once improvement, so the gains below are additional. Measurements below describe the frozen build hashes linked at the end; no installed executable was replaced.

## Measured results

macOS 15.6.1, release binaries, one disposable 900×708-point window captured at 1800×1416 native pixels, PNG, cursor excluded. Each timing condition has three warmups and 15 alternating/randomized paired samples. Request time includes capture, compression, disk write, JSON/base64 and stdio transfer. Decoding happens outside timing.

| Window-ID capture condition | Baseline p50 | Candidate p50 | Median reduction | Baseline p95 | Candidate p95 |
|---|---:|---:|---:|---:|---:|
| Persistent sessions, repeated capture | 144.875 ms | 112.846 ms | 22.1% | 215.939 ms | 191.378 ms |
| Enumeration cache expired before each request | 215.840 ms | 193.732 ms | 10.2% | 228.936 ms | 259.816 ms |

The candidate was faster in 13/15 repeated-capture pairs and 12/15 expired-cache pairs. Paired median savings were 32.386 ms (bootstrap 95% interval 26.628–35.699 ms) and 27.305 ms (11.931–31.414 ms), respectively. These are small, local samples, not universal latency guarantees. The expired-cache p95 regressed; no tail-latency improvement is claimed.

All static paired PNG captures passed exact decoded RGBA8 pixel equality at native dimensions, and image files were 427,226 bytes in both variants. The eight-byte response-size difference comes from variant path labels, not image compression. No capture scale, codec quality, cursor behavior or pixel format setting was changed.

## Highest-value changes

1. **Remove redundant enumeration.** `Targets.resolveWindow` passes the display snapshot it already fetched to `ScreenCaptureKitCapturer`. The normal cold window path needs one ScreenCaptureKit enumeration instead of two; an unchanged numeric target inside the cache lifetime avoids the capturer's extra enumeration. Cheap WindowServer geometry checks detect move, resize, visibility and display-layout changes. App-name targets refresh ordering so switching frontmost windows cannot reuse stale order. Manually constructed window handles still have the original enumeration fallback.
2. **Coalesce simultaneous cache misses.** At the same two-second TTL, a gated 20-request burst made 20 fetches with the previous implementation and one with the candidate: 95% fewer duplicate fetches. This proves work reduction in the cache, not a measured 95% screenshot-latency improvement. Errors remain uncached, zero TTL stays fresh, cancellation of one waiter cannot cancel another's producer, and invalidated/superseded results cannot overwrite a refreshed entry.

## Freshness and coordinate acceptance

The candidate captured changed content and correct geometry before its two-second cache could expire. Total time from the beginning of pre-change warmup through post-change capture was 0.760 s for marker change, 0.837 s for resize, and 0.757 s for move. Checks include a 0.2 s publication allowance before reading current WindowServer geometry.

- Marker: red changed to black and the next capture showed the changed marker.
- Resize: candidate reported 780×588 points instead of 900×708; pixel size matched the native scale. The baseline's immediate capture retained stale dimensions.
- Move: candidate origin changed from (130,279) to (165,254). The baseline's immediate metadata retained the prior origin.
- Candidate marker, dimensions and bounds matched a fresh baseline reference taken after cache expiry.

A strict whole-frame comparison across the delayed reference initially failed in the test harness. Retained evidence shows the candidate and immediate baseline were exactly equal across all 10,195,200 RGBA channels; two baseline frames separated by the delay themselves differed by one channel level in 2,316,779 channels and two levels in three channels. Dynamic checks therefore assert current content and geometry; the static timing cases retain strict full-frame equality. The first resize acknowledgment also preceded WindowServer publication, so the fixture now reads authoritative bounds after the publication allowance. These were benchmark corrections; production code did not change during these runs.

## Cold-start limit and other unmeasured cases

A cold-server run did not complete the required paired sample count. A diagnostic localized the baseline timeout to the screenshot request after successful initialization; the process sample shows ReplayKit/replayd XPC connection-error activity. The candidate's first diagnostic cold capture completed in 254.166 ms, but there is no valid paired cold-start speedup estimate. The original run used a 30 s timeout; the diagnostic used 5 s and sampled the stalled process. No system daemon was restarted and no workaround was included in the timing results.

Full-display capture, JPEG latency, multiple monitors, display mode changes and sustained concurrent live captures were not benchmarked in this pass. The display bounds guard is implemented; no improvement is claimed for these unmeasured cases. Persistent SCStream reuse and optional smaller images remain separate experiments: this pass preserves fresh native-resolution capture.

## Verification and evidence

`SCREENCOMMANDER_PERF_AB=1 swift test -c release`: 288 tests executed, one unrelated live-AX test skipped, zero failures. Production source hashes were recorded after the final build and verified unchanged after live testing.

- [Static paired samples](capture-ab.json) (warm and TTL conditions complete; overall status is partial because cold startup timed out)
- [Paired estimates](paired-estimates.json)
- [Passing dynamic acceptance](capture-acceptance-final.json)
- [Concurrent fetch-count A/B](cache-burst-ab.json)
- [Release test log](release-tests.log)
- [Baseline temporal pixel variation](temporal-pixel-differences.json) and [colored-marker control](temporal-color-control.json)
- [Cold diagnostic](capture-cold-diagnostic.json), [stage log](capture-cold-diagnostic.log), [process sample](baseline-cold-timeout.sample.txt)
- [Production source hashes](source-sha256.json), [current harness hashes](harness-sha256.json)

Earlier failed harness runs are retained alongside the final evidence. Capture-only images and diagnostic binaries are retained in each diagnostic JSON's `scratchPath`; all fixture/server processes were closed. Reproduction commands and scope are in [bench/README.md](../README.md).

Baseline SHA-256: `c53ec354c35cb3937b6943ccd3c03f2f00633fc63cc8bed1e0001e49603b338d`.

Candidate SHA-256: `cb099ad81ab29d4e27918f7a50a62689f423ef4a9cf658a24bd6780890fe48f9`.

Final PR review subsequently added caller-cancellation checks to shared enumeration. See the [Astra review and final validation](../review-results/REPORT.md) for final source hashes, regression coverage and post-review capture results.
