# Follow-Up Design Issues

This document tracks the remaining design issues from the hostile review that were not folded into the current bug-fix pass. These are intentionally separated because they change protocol behavior, runtime concurrency, output defaults, or documentation ownership.

## Concurrent MCP Serve

Intent: prevent one long `observe_wait` from blocking every other MCP request.

Decision: support both parallel and serial request execution. If a second request arrives without an explicit serial dependency, treat it as parallel by default.

What to do: move `serve --mcp` to a request dispatcher with serialized stdout writes, request-id cancellation, and an explicit way for a client to chain a request behind an upstream request that is still queued or running.

Serial semantics: a serial request represents a follow-on action that depends on upstream activity. It should not start until the request it depends on has completed, even while unrelated requests continue in parallel.

Downside: shared server state must be hardened, request cancellation has to understand dependency chains, and clients need a clear protocol field for expressing "run this after that" without accidentally serializing unrelated work.

## Stale Metadata Validation

Intent: make callers aware when screenshot metadata may no longer describe the live desktop, especially when a human is using the computer at the same time.

Decision: treat freshness as information by default, not a mandatory hard failure. This matters less for background accessibility actions, and even for coordinate actions some workflows may accept that the desktop changed between observe and act.

What to do: validate live display/window geometry when practical and return freshness information in action results, such as `metadataFresh: true|false` plus a reason. Add a strict mode for chains that require deterministic coordinate safety, where stale metadata becomes a `stale_metadata` error.

Downside: advisory metadata can be ignored by sloppy callers, while strict mode can still false-positive on harmless geometry drift. Every live freshness check also adds some runtime cost.

## Frame Diff Policy

Intent: make the "did anything change?" signal useful for small UI changes on large Retina screens.

Decision: keep the fixed `64x64 / 0.04` default for compatibility.

What to do: expose CLI and MCP override knobs for callers that need a different grid size or threshold. The default behavior should remain unchanged unless the caller opts in.

Downside: new knobs add surface area and documentation burden, and callers can tune themselves into noisy or overly insensitive diffs.

## Docs Consolidation

Intent: stop `README.md`, `SKILL.md`, `AGENTS.md`, `INIT.md`, and `docs/capability-plan.md` from telling different stories.

Decision: `docs/capability-plan.md` is legacy and can be removed. `INIT.md` was the original implementation tracker and can also be removed now if it no longer reflects the current project state.

What to do: make `README.md` the GitHub-facing project README and current user contract. Make `SKILL.md` the short operator runbook for agents running the CLI. Keep `AGENTS.md` limited to repo-specific instructions for agents working in this repository. Remove legacy planning/tracker docs instead of trying to keep them synchronized.

Downside: none if the cleanup is accurate. Before deleting or rewriting a doc, check whether the apparent conflict is just historical context from when that doc was created; if it is historical and no longer authoritative, remove it or clearly retire it.

## CLI/MCP Parsing Deduplication

Intent: avoid flags drifting between CLI, MCP, and sequence JSON.

What to do: keep surface-specific parsing, but centralize request construction and semantic validation in small helpers.

Downside: if overdone, this becomes a fake parser framework; the fix should stay boring and targeted.
