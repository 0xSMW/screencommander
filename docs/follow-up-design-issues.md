# Follow-Up Implementation Plan

This is the working plan for the remaining agreed follow-up work. It tracks only items we intend to implement or clean up.

## 1. MCP Serve Request Scheduling

### Goal

`serve --mcp` must support concurrent requests without head-of-line blocking, while also allowing clients to explicitly chain dependent requests serially.

### Product Contract

- Requests run in parallel by default.
- A request can opt into serial execution by declaring that it depends on an upstream request.
- A serial follow-on request starts only after its upstream request has completed.
- Unrelated requests continue running while a serial chain is queued or active.
- `notifications/cancelled` can cancel an in-flight request by id.
- Cancellation semantics for a serial chain must be explicit: canceling an upstream request should prevent dependent queued requests from running unless the protocol says otherwise.

### Files To Change

- `Sources/ScreenCommander/CLI/ServeCommand.swift`
  - Replace the inline `readLine` / `await server.handle(line:)` loop with a serve-session dispatcher.
  - Keep stdin reading continuous.
  - Dispatch each request into the scheduler.
- `Sources/ScreenCommander/MCP/MCPServer.swift`
  - Keep JSON-RPC parsing/response formatting here, but remove assumptions that calls are serialized by the transport loop.
  - Protect or move mutable server state such as initialization state.
- `Sources/ScreenCommander/MCP/MCPToolRegistry.swift`
  - Add any MCP argument/schema fields needed for serial dependency metadata if the dependency is expressed inside tool calls.
  - Keep tool handlers independent of transport scheduling where possible.
- `Sources/ScreenCommander/Persistence/SnapshotMetadataStore.swift`
  - Make concurrent `save`/`load` safe if MCP requests can overlap.
  - Prefer local `JSONEncoder` / `JSONDecoder` instances per call or a small lock.
- `docs/json-output-schema.md`
  - Document any new request/dependency field if it becomes part of the MCP-facing contract.
- `README.md`
  - Document `serve --mcp` scheduling behavior: parallel by default, serial when chained.
- `SKILL.md`
  - Add operator guidance for when to use serial chaining.

### Implementation Steps

1. Add a `MCPServeSession` or `MCPRequestDispatcher` owned by `ServeCommand`.
2. Add a stdout writer actor or queue so response lines cannot interleave.
3. Add an in-flight task registry keyed by JSON-RPC request id.
4. Add dependency tracking for serial follow-on requests.
5. Support `notifications/cancelled` by canceling the matching task.
6. Define what happens to queued dependents when their upstream request is canceled or fails.
7. Harden shared state that becomes reachable concurrently.

### Tests

- Add serve-session tests for a long `observe_wait` plus a quick second request; the second response must return before `observe_wait` completes.
- Add cancellation tests for an in-flight `observe_wait`.
- Add serial-chain tests proving a dependent request waits for its upstream request.
- Add parallel tests proving unrelated requests do not wait for a serial chain.
- Add snapshot metadata store concurrency coverage if the store is hardened.

### Acceptance Criteria

- A long `observe_wait` cannot block unrelated MCP requests.
- A serial follow-on request can be expressed and waits behind its upstream request.
- Response lines remain valid NDJSON/JSON-RPC and never interleave.
- Canceled requests stop work and do not emit a late success response.
- `swift test` passes.

## 2. Metadata Freshness Signal

### Goal

Coordinate actions should surface whether the screenshot metadata still appears to describe the live desktop, without making freshness a hard failure by default.

### Product Contract

- Metadata freshness is informational by default.
- Coordinate actions can report freshness status in their result.
- Strict coordinate workflows can opt into failing when metadata is stale.
- Background accessibility actions are not blocked by coordinate metadata freshness.

### Files To Change

- `Sources/ScreenCommander/Core/ScreenCommanderEngine.swift`
  - Validate metadata freshness before coordinate `click`, `scroll`, `drag`, and `move` when practical.
  - Include freshness information in coordinate action results.
  - Add strict-mode failure behavior for coordinate workflows if a strict freshness flag is introduced.
- `Sources/ScreenCommander/Core/CoordinateMapping.swift`
  - Keep pure coordinate mapping unchanged.
  - Do not add live-system checks here.
- `Sources/ScreenCommander/Core/Errors.swift`
  - Add `staleMetadata` / `stale_metadata` only if strict mode can fail.
- `Sources/ScreenCommander/Persistence/Models.swift`
  - Add result fields for freshness reporting, likely on coordinate action result models.
  - Consider a compact model such as `MetadataFreshnessResult`.
- `Sources/ScreenCommander/Core/Targets.swift`
  - Reuse window/display lookup helpers if freshness validation needs live window geometry.
- `Sources/ScreenCommander/Core/Displays.swift` or a new `Sources/ScreenCommander/Core/CaptureFreshness.swift`
  - Add live display/window geometry validation helpers.
- CLI command files for coordinate actions:
  - `Sources/ScreenCommander/CLI/ClickCommand.swift`
  - `Sources/ScreenCommander/CLI/ScrollCommand.swift`
  - `Sources/ScreenCommander/CLI/DragCommand.swift`
  - `Sources/ScreenCommander/CLI/MoveCommand.swift`
  - Add any strict freshness flag if needed.
- `Sources/ScreenCommander/MCP/MCPToolRegistry.swift`
  - Expose the same strict freshness option if added to CLI.
- `docs/json-output-schema.md`
  - Document freshness fields and `stale_metadata` if introduced.
- `README.md`
  - Explain advisory freshness and strict freshness behavior.
- `SKILL.md`
  - Tell agents how to interpret freshness info during action chains.

### Implementation Steps

1. Define the result model for freshness information.
2. Implement live display validation for display-scoped metadata.
3. Implement live window validation for window-scoped metadata when the window id is present.
4. Thread freshness info through coordinate action results.
5. Add strict failure behavior only for callers that request it.
6. Keep missing/unavailable freshness checks advisory unless strict mode is active.

### Tests

- Coordinate click reports fresh metadata when live geometry matches.
- Coordinate click reports stale metadata when display geometry differs.
- Window-coordinate action reports stale metadata when the window is gone or moved beyond tolerance.
- Strict freshness mode throws `stale_metadata`.
- Non-strict mode still performs the action and includes freshness info.
- `elements` behavior remains independent unless explicitly changed.

### Acceptance Criteria

- Freshness appears in JSON output for coordinate actions.
- Default coordinate actions do not fail solely because metadata is stale.
- Strict freshness mode can fail deterministically.
- Background AX actions are unaffected.
- `swift test` passes.

## 3. Frame Diff Tuning

### Goal

Keep the current frame diff behavior by default, while allowing callers to tune the diff grid and threshold when the default is too coarse or too sensitive.

### Product Contract

- Default frame diff remains `64x64` grid with `0.04` threshold.
- CLI and MCP callers can override grid size and threshold.
- Existing callers get the same output unless they opt into overrides.

### Files To Change

- `Sources/ScreenCommander/Capture/FrameDiff.swift`
  - Keep current defaults.
  - Validate custom grid and threshold values.
- `Sources/ScreenCommander/CLI/RootCommand.swift`
  - Allow `CommandRuntime.frameDiff` to accept a config object instead of calling `FrameDiff.compare` with defaults only.
- CLI action commands:
  - `Sources/ScreenCommander/CLI/ClickCommand.swift`
  - `Sources/ScreenCommander/CLI/TypeCommand.swift`
  - `Sources/ScreenCommander/CLI/KeyCommand.swift`
  - `Sources/ScreenCommander/CLI/KeysCommand.swift`
  - `Sources/ScreenCommander/CLI/ScrollCommand.swift`
  - `Sources/ScreenCommander/CLI/DragCommand.swift`
  - `Sources/ScreenCommander/CLI/MoveCommand.swift`
  - `Sources/ScreenCommander/CLI/SequenceCommand.swift`
  - Add flags such as `--diff-grid` and `--diff-threshold`.
- `Sources/ScreenCommander/MCP/MCPToolRegistry.swift`
  - Add matching tool arguments for actions that return diffs.
- `Sources/ScreenCommander/Persistence/Models.swift`
  - Add config/result fields only if output needs to report the effective diff config.
- `docs/json-output-schema.md`
  - Update only if output includes effective diff config.
- `README.md`
  - Document the override flags.
- `SKILL.md`
  - Add short guidance for tuning small UI changes.

### Implementation Steps

1. Define `FrameDiffConfig` with defaults matching current behavior.
2. Add validation for grid and threshold.
3. Thread config from CLI/MCP action surfaces into `CommandRuntime.frameDiff`.
4. Keep `--no-diff` behavior unchanged.
5. Decide whether result output should include effective config; if yes, document it.

### Tests

- Existing default frame diff tests continue to pass.
- Default action path still uses `64x64 / 0.04`.
- Custom grid/threshold reaches `FrameDiff.compare`.
- Invalid grid/threshold returns `invalid_arguments`.
- MCP action arguments mirror CLI behavior.

### Acceptance Criteria

- No default diff behavior changes.
- CLI callers can override grid and threshold.
- MCP callers can override grid and threshold.
- Invalid tuning values fail clearly.
- `swift test` passes.

## 4. Documentation Consolidation

### Goal

Make each documentation file own one clear job and remove legacy docs that no longer represent the current project.

### Product Contract

- `README.md` is the GitHub-facing project README and current user contract.
- `SKILL.md` is the short operator runbook for agents using the CLI.
- `AGENTS.md` is repo-specific instruction for agents working in this repository.
- `docs/capability-plan.md` is legacy and can be removed.
- `INIT.md` was the original implementation tracker and can be removed if it is no longer current.
- Docs must not tell conflicting stories about shipped behavior.

### Files To Change

- `README.md`
  - Keep the full current user-facing command contract here.
  - Remove references to legacy tracker status.
- `SKILL.md`
  - Keep concise operator workflows and troubleshooting.
  - Link to `README.md` for exhaustive syntax instead of duplicating every command detail.
- `AGENTS.md`
  - Keep repo-specific agent workflow and project instructions.
  - Remove command-manual duplication that belongs in `README.md` or `SKILL.md`.
- `docs/capability-plan.md`
  - Delete if no current content remains.
- `INIT.md`
  - Delete if no current content remains.
- `docs/json-output-schema.md`
  - Keep as the machine-readable output contract.

### Implementation Steps

1. Audit each doc for current behavior, historical planning text, and duplicated command semantics.
2. Move or preserve current user contract content in `README.md`.
3. Reduce `SKILL.md` to the operator runbook.
4. Reduce `AGENTS.md` to repo-agent instructions.
5. Delete `docs/capability-plan.md` if it is only legacy planning.
6. Delete `INIT.md` if it is only legacy tracker content.
7. Run a final terminology pass for click semantics, metadata freshness, MCP serve behavior, and frame diff tuning.

### Tests / Verification

- `rg` for removed legacy claims after deleting/rewriting docs.
- `swift run screencommander --help` spot-check if command help changed during doc cleanup.
- Verify `README.md`, `SKILL.md`, and `AGENTS.md` each describe the same defaults.

### Acceptance Criteria

- No shipped command is described as future work.
- No legacy plan doc remains as an apparent source of truth.
- `README.md`, `SKILL.md`, and `AGENTS.md` have distinct ownership.
- `docs/json-output-schema.md` remains the output contract.
