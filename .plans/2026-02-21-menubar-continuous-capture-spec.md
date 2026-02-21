# ScreenCommander Future Spec: Menubar Continuous Capture + Post-Action Refresh

Date: 2026-02-21  
Status: Future / Not Implemented  
Scope: Design spec only

## Problem

Current usage is command-driven and snapshot-based. Agents can lose context between actions unless they manually recapture. For UI automation loops, we want near-real-time desktop state with predictable freshness and bounded disk usage.

## Proposal

Add an optional macOS menubar companion process that:

1. Captures screenshots on a configurable interval.
2. Captures immediate post-action screenshots when click/type/key/sequence steps complete.
3. Stores captures in managed cache directories with aggressive eviction defaults.

## Goals

- Keep desktop state fresh for model-driven decisions.
- Preserve deterministic mapping metadata for every image.
- Avoid unbounded storage growth from frequent Retina screenshots.
- Keep CLI compatibility: existing one-shot commands continue to work.

## Non-Goals

- Replacing CLI workflows entirely.
- Building cloud sync or remote transport in v1.
- Implementing app-specific logic in capture daemon.

## User Experience

### Menubar Controls

- `Continuous Capture: On/Off`
- `Interval: 5s / 10s / 30s / 60s / Custom`
- `Capture on Action: On/Off` (default On)
- `Retention Window: 5 min / 15 min / 60 min / Custom`
- `Open Capture Folder`
- `Pause for N minutes`

### CLI Interop

- CLI actions continue to run normally.
- When menubar companion is active, actions trigger post-action capture hooks.
- CLI can query latest frame path and freshness.

## Architecture (Future)

### Components

1. `screencommanderd` (menubar/app process)
   - Owns timer capture loop.
   - Owns retention/eviction.
   - Publishes latest frame index.

2. Shared state store
   - Capture images + metadata JSON.
   - Latest pointers.
   - Optional lightweight index manifest.

3. CLI integration
   - Existing commands read/write shared state paths.
   - Action commands emit hook events (or write trigger files) for daemon post-action capture.

## Data & Paths

Suggested managed base directory:

- `~/Library/Caches/screencommander/captures/`

Suggested layout:

- `captures/YYYYMMDD/HH/Frame-<timestamp>.png`
- `captures/YYYYMMDD/HH/Frame-<timestamp>.json`
- `captures/latest.json` (pointer)
- `captures/index.jsonl` (optional append-only summary)

## Cache & Retention Policy

### Why change from long retention

Retina captures are large; high-frequency intervals can create GB-scale growth quickly.

### Proposed defaults

- Interval capture retention default: **5 minutes**.
- Post-action captures retention default: **15 minutes**.
- Hard disk guardrail: max size threshold (example 2 GB), with oldest-first eviction.

### Eviction Strategy

1. Time-window eviction first.
2. If still above size threshold, evict oldest until under limit.
3. Never leave pointers dangling (atomic pointer updates).

## Capture Cadence

- Interval capture ticks at configured cadence (default recommendation: 10s).
- Action-triggered capture runs immediately after input command completion.
- Dedup optimization (optional): skip write if visual hash unchanged from prior frame.

## Permissions

- Menubar process needs Screen Recording.
- CLI keeps Accessibility for input injection.
- Clear permission diagnostics in both menubar UI and CLI `doctor` output.

## Reliability Requirements

- Capture + metadata must be atomic as a pair.
- Pointer updates must be atomic.
- Failures should not block action commands.
- If post-action capture fails, action still reports success with capture warning.

## API/Command Additions (Future)

Potential CLI additions:

- `screencommander watch start --interval 10s`
- `screencommander watch stop`
- `screencommander watch status`
- `screencommander frame latest [--json]`
- `screencommander cache prune --window 5m --max-size 2GB`

Potential action flags:

- `--capture before|after|both|none` (default `both` when watch active)

## Performance Considerations

- Use ScreenCaptureKit efficiently; avoid overlapping captures.
- Backpressure if capture falls behind interval.
- Keep JSON metadata minimal and fixed schema.

## Security & Privacy

- Store only local cache by default.
- No network upload in v1.
- Clear local-only retention controls.

## Rollout Plan

Phase 1: Spec + shared path contract.  
Phase 2: Menubar app skeleton + interval capture + retention.  
Phase 3: CLI hook integration for post-action capture.  
Phase 4: Status/health commands + docs + migration notes.

## Acceptance Criteria (Future)

- Menubar app can run continuously and capture at configured interval.
- Action commands trigger post-action capture while companion is active.
- Cache retention defaults enforce short window (5 min interval frames).
- Latest frame pointer always valid and recent.
- Disk usage remains bounded under stress test.

## Open Questions

- Preferred default interval: 5s vs 10s?
- Should post-action captures have separate retention class from interval captures?
- Should we support per-display continuous capture in v1?
- Should dedup hashing be enabled by default?
