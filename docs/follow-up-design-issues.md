# Follow-Up Design Issues

This document tracks the remaining design issues from the hostile review that were not folded into the current bug-fix pass. These are intentionally separated because they change protocol behavior, runtime concurrency, output defaults, or documentation ownership.

## Concurrent MCP Serve

Intent: prevent one long `observe_wait` from blocking every other MCP request.

What to do: move `serve --mcp` to a per-request task dispatcher with serialized stdout writes and request-id cancellation.

Downside: shared server state must be hardened, and we need an explicit decision about whether mutating desktop actions can run concurrently or need a serial mutation lane.

## Stale Metadata Validation

Intent: stop clicks from trusting old screenshot geometry after windows or displays move.

What to do: validate live display/window geometry before coordinate actions and fail with `stale_metadata` when the saved capture no longer describes the desktop.

Downside: harmless geometry drift can create false positives, and every coordinate action pays for extra live-state checks.

## Frame Diff Policy

Intent: make the "did anything change?" signal useful for small UI changes on large Retina screens.

What to do: replace the fixed `64x64 / 0.04` policy with an adaptive or configurable policy.

Downside: `changedFraction` and `changedRegion` values will shift for scripts that compare exact diff numbers.

## Action Feedback Captures

Intent: reduce the cost of every action doing full pre/post screenshot capture by default.

What to do: introduce an explicit feedback policy, likely defaulting to lighter post-action feedback while keeping full before/after diff as an opt-in mode.

Downside: users lose some automatic debugging context unless they request the heavier mode.

## Window Capture Re-Enumeration

Intent: avoid resolving the same window/display information twice during `screenshot --window`.

What to do: carry display metadata from window resolution into capture so ScreenCaptureKit content is not re-enumerated.

Downside: there is a small freshness risk if the window moves between resolve and capture, so the capturer still needs a fallback or revalidation path.

## Docs Consolidation

Intent: stop `README.md`, `SKILL.md`, `AGENTS.md`, `INIT.md`, and `docs/capability-plan.md` from telling different stories.

What to do: make `README.md` the current user contract, `SKILL.md` the short operator runbook, `AGENTS.md` repo workflow only, `INIT.md` implementation tracker only, and `docs/capability-plan.md` future roadmap only.

Downside: this is a broad documentation cleanup with many deletions, which can be noisy in review.

## CLI/MCP Parsing Deduplication

Intent: avoid flags drifting between CLI, MCP, and sequence JSON.

What to do: keep surface-specific parsing, but centralize request construction and semantic validation in small helpers.

Downside: if overdone, this becomes a fake parser framework; the fix should stay boring and targeted.

## AX Priming Churn

Intent: reduce repeated AX attribute toggling for Electron and Chromium apps.

What to do: first measure whether repeated `AXManualAccessibility` / `AXEnhancedUserInterface` priming is costly or destabilizing, then consider per-app memoization in serve mode.

Downside: caching AX priming state can get stale and may leave side effects around longer than the current restore-after-read model.
