# ScreenCommander performance A/B — September 22, 2026

Branch: `perf/ax-multiturn-ab`. Baseline: `ba0496ee616b1c2f79ebf9da73251fd853f72489`. Measurements below describe the frozen build hashes linked at the end.

The targeted changes show measurable gains across all six opportunity categories on the controlled fixtures. General unfiltered tree reads do **not** show a consistent improvement. Budgeted reads return explicitly incomplete results; their speed is not an equal-work comparison.

## Final live results

Both binaries were release builds of the same Swift package/toolchain. Each scenario used warm MCP servers, three warmup pairs and 15 measured pairs with balanced/randomized order. The dedicated AppKit fixture exposed **547 AX records**, including 520 buttons, sparse controls and a 140,000-character document. No personal app content was used.

| Opportunity and workload | A → B, median | Result and interpretation |
|---|---:|---|
| 1. Resolve known element directly | 192.192 → 103.235 ms | **46.3% faster** AX click; the intended fixture counter incremented exactly once per action. |
| 2. Filter before hydration | 149.209 → 41.236 ms | **72.4% faster** sparse-role read; identical records. |
| 2. Text projection/ranged text | 169.759 → 106.855 ms | **37.1% faster**; identical rendered text; 288,753 → 186,319 response bytes. |
| 3. Snapshot delta after one counter change | 256,712 → 1,425 bytes | **99.4% smaller** response; reconstructing the delta exactly matched a fresh full observation. AX is still read afresh. |
| 3. Action plus observation | 343.506 → 252.949 ms | **26.4% faster** complete loop, **two tool calls → one**. This includes the other AX optimizations; it does not isolate round-trip savings or measure model inference time. |
| 4. Visited-node budget | 547 → 90 visited nodes; B 32.464 ms | Work is bounded independently of emitted results. B reports `truncated` and a partial reason. **Different work**, not equivalent full-tree output. |
| 5. Observer record hydration, real AX window | 0.212458 → 0.104292 ms | **50.9% faster**; identical complete records across 20 alternating pairs after three warmups. Measures AX record reads, not event delivery. |
| 6. Full window screenshot via MCP | 191.020 → 164.631 ms | **13.8% faster**, unchanged response bytes and equivalent image dimensions. |

Final within-run paired bootstrap 95% intervals for median latency gains: direct action 45.0–46.8%, filtered reads 65.5–74.0%, text 30.6–47.1%, combined action/read 25.0–28.2%, and screenshots 12.3–21.4%. These intervals use 10,000 resamples and describe this run, not variation across apps or days.

The initial run is retained separately. It also passed all semantic checks and measured direct actions 50.1%, filters 60.3%, text 45.6%, and screenshots 13.7% faster. The initial screenshot interval included zero; the final run did not. Capture scheduling remains noisier than the isolated encoding comparison.

## Isolated component evidence and tradeoffs

- Screenshot encoding plus metadata handling: generated 960×640 PNG, four warmups and 20 alternating measured pairs. Median **9.761 → 4.928 ms** (49.5% faster), total process CPU **0.185 → 0.094 s**. Old/new file bytes match exactly. PNG and JPEG output-byte/size checks pass.
- Synthetic 2,000-record snapshot with 1% changed records: **852,838 → 9,198 wire bytes**; 20 changed records. This is a payload comparison, not an AX traversal speedup.
- Observer hydration replaces seven individual scalar reads with one batch, retaining separate action and geometry reads. A mock-only CPU test was slower (13.412 → 17.002 ms per 10,000 records) because batching adds local array/coercion work. Real cross-process AX reads benefited. The mock result is retained rather than represented as a speedup.
- General full-tree reads: first run **157.030 → 149.686 ms**; final run **177.280 → 189.827 ms** (7.1% slower point estimate). The final bootstrap interval spans a 27.0% regression to a 23.8% gain. **No reliable full-tree speedup is established**; specialized reads and deltas are the demonstrated wins.
- The live comparisons test the complete optimized build against the frozen baseline. They do not separately attribute every millisecond to each internal change.

## Correctness and scope

The final release suite reports **279 tests, zero failures**, with the live-observer test skipped until its dedicated fixture was running; that selected test then passed separately. CLI help and `git diff --check` passed. Action counters, AX record/text equivalence, delta reconstruction, image bytes/dimensions, missing/short child pages, delivered-action receipt marking, partial-read handling, snapshot eviction, and retained timeout observations are covered.

Implementation details relevant to callers:

- Direct IDs resolve in the current focused-window scope and retain a live reference through that action. IDs are still positional; durable cross-UI identity handles are not introduced. Direct lookup bypasses the old 2,000-record search cap while retaining the depth limit.
- Text profile preserves scalar state, including disabled/focused state; geometry/actions are unqueried. Long supported text uses a bounded ranged read with fallback.
- Visited budgets and cooperative deadlines mark incomplete results. A failed or short expected child page cannot become an authoritative snapshot or imply removals.
- Snapshot storage retains at most eight entries under an estimated 8 MiB content budget. A missing/incompatible/oversized baseline returns an explicit full reset. Deltas do not avoid the underlying AX read and do not use a notification-driven cache.
- `postObserve` is optional and immediate. It does not promise asynchronous UI settling. A post-read failure preserves successful action delivery; cancellation after delivery preserves its receipt.
- Predicate timeouts retain bounded collected observations while preserving error code 73. The collector uses a ring buffer. The upstream observer stream remains lossless and unbounded; coalescing/persistent subscriptions are not claimed as implemented.
- MCP's existing structured-plus-text envelope remains compatible. The main output reduction comes from projected fields and deltas.

## Reproduce and inspect

See [benchmark instructions](../README.md). The baseline source was frozen with `git archive` before edits; neither installed binary was replaced. The live harness terminated its own fixture/servers and restored focus when appropriate.

- [Final paired raw samples and binary hashes](live-ab.json)
- [Initial run](live-ab-first-pass.json)
- [Bootstrap estimates](paired-estimates.json)
- [Component measurements](component-ab.json)
- [Release correctness and component-test log](release-tests.log)
- [Real AX observer test log](live-observer.log)
- [Changed source SHA-256 manifest](source-sha256.json)

Final PR review subsequently added caller-cancellation checks to shared enumeration. See the [Astra review and final validation](../review-results/REPORT.md) for final source hashes, regression coverage and post-review capture results.
