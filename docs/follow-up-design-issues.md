# Follow-Up Implementation Spec

This document is the working implementation spec for the remaining agreed follow-up work. Keep it current as decisions change. Each section should describe the intended behavior, the files involved, the concrete code changes, and the acceptance checks.

## 1. MCP Serve Request Scheduling

### Intent

`serve --mcp` should keep accepting requests while slow tools are still running. Requests run concurrently by default. A caller can explicitly serialize a follow-on request by declaring that it depends on an earlier request id.

### Protocol Contract

- Requests without a dependency start as soon as they are received.
- A request with `params.dependsOn` waits for that request id while it is still running.
- If the dependency has already completed, the dependent request can start immediately.
- `notifications/cancelled` with `params.requestId` cancels the matching in-flight request.
- Canceling an upstream request also cancels queued dependents that were waiting on it.
- Response lines are serialized on stdout so JSON-RPC output never interleaves.

### File Plan

- `Sources/ScreenCommander/CLI/ServeCommand.swift`
  - Replace the inline `readLine()` loop that awaits each request with a serve-session dispatcher.
  - Keep stdin reading synchronous and continuous.
  - Route each raw line into the dispatcher.
  - Write responses through a locked stdout writer.
  - On EOF, wait for currently tracked tasks to finish or cancel according to dispatcher behavior.

- `Sources/ScreenCommander/MCP/MCPServeSession.swift`
  - Add this file as the transport-level scheduler.
  - Decode JSON-RPC once per input line.
  - Handle parse errors immediately with JSON-RPC parse-error responses.
  - Track in-flight request tasks by JSON-RPC id.
  - Track dependency edges from upstream request id to dependent request ids.
  - Start unrelated requests in independent tasks.
  - Wait on the upstream task when `params.dependsOn` names an active request.
  - Suppress late success/error responses for canceled requests.
  - Remove completed tasks from the registry so long-running sessions do not grow unbounded.

- `Sources/ScreenCommander/MCP/MCPServer.swift`
  - Keep request routing, tool dispatch, and JSON-RPC response formatting here.
  - Add an entry point that accepts an already-decoded `JSONRPCRequest`.
  - Keep `handle(line:)` as a compatibility wrapper around decode plus request handling.
  - Protect mutable shared server state, especially initialization state, because requests can now overlap.

- `Sources/ScreenCommander/MCP/MCPToolRegistry.swift`
  - Keep tool handlers unaware of transport scheduling.
  - Do not add tool arguments for dependency metadata; request ordering belongs at the JSON-RPC request layer through `params.dependsOn`.

- `Sources/ScreenCommander/Persistence/SnapshotMetadataStore.swift`
  - Remove shared mutable `JSONEncoder` and `JSONDecoder` instances.
  - Create local encoders and decoders per call.
  - Confirm concurrent `save` and `load` calls do not corrupt metadata.

- `Tests/ScreenCommanderTests/MCPServerTests.swift`
  - Add a serve-session test where a long `observe_wait` is in flight and a quick request still returns.
  - Add a dependency test where request B waits for request A.
  - Add a cancellation test where canceling request A suppresses A and any queued dependent B.
  - Add a stdout ordering test if response collection can otherwise hide interleaving.

- `Tests/ScreenCommanderTests/SnapshotMetadataStoreTests.swift`
  - Add concurrent save/load coverage against the same store instance.

- `README.md`
  - Document `serve --mcp` as parallel by default.
  - Document `params.dependsOn` for clients that need ordered follow-on actions.
  - Document cancellation behavior.

- `SKILL.md`
  - Add operator guidance for when an agent should use `dependsOn`.
  - Mention that independent reads or diagnostics should stay parallel.

- `docs/json-output-schema.md`
  - Document `params.dependsOn` and `notifications/cancelled`.

### Acceptance Checks

- A long `observe_wait` does not block an unrelated MCP request.
- A dependent request waits for its upstream request.
- Canceling an upstream request cancels queued dependents.
- JSON-RPC responses remain valid one-line JSON objects.
- Concurrent metadata save/load tests pass.
- `swift test` passes.

## 2. Metadata Freshness Signal

### Intent

Coordinate actions should report whether the screenshot metadata still appears to match the live desktop. Freshness is advisory by default, with an opt-in strict mode for workflows that want stale metadata to fail.

### Product Contract

- Coordinate actions include a `metadataFreshness` result when metadata is used.
- Default behavior reports freshness and continues.
- Strict freshness mode fails with `stale_metadata` when the metadata is known stale.
- Unknown freshness is reported as `unknown`; default behavior still continues.
- Background AX element actions are not blocked by coordinate metadata freshness.

### File Plan

- `Sources/ScreenCommander/Persistence/Models.swift`
  - Add `MetadataFreshnessResult`.
  - Include fields for status, reason, and checked scope.
  - Add optional `metadataFreshness` to coordinate action result models:
    - `ClickResult`
    - `ScrollResult`
    - `DragResult`
    - `MoveResult`

- `Sources/ScreenCommander/Core/CaptureFreshness.swift`
  - Add a new freshness checker.
  - Validate display-scoped metadata by comparing captured display id and bounds against live display state.
  - Validate window-scoped metadata by checking whether the captured window id still exists and whether bounds still match within a small tolerance.
  - Return `unknown` when live validation is unavailable.
  - Keep all live system checks out of coordinate mapping.

- `Sources/ScreenCommander/Core/ScreenCommanderEngine.swift`
  - Inject the freshness checker through the engine dependency set.
  - Run freshness checks before coordinate `click`, `scroll`, `drag`, and `move`.
  - Attach freshness results to action results.
  - If strict freshness is enabled and status is `stale`, throw `stale_metadata`.
  - Leave AX element actions on their current path.

- `Sources/ScreenCommander/Core/CoordinateMapping.swift`
  - Keep this pure and metadata-only.
  - Do not add live display or live window lookup here.

- `Sources/ScreenCommander/Core/Errors.swift`
  - Add `staleMetadata` / `stale_metadata`.
  - Error text should identify which metadata scope is stale and tell the caller to recapture.

- `Sources/ScreenCommander/Core/Targets.swift`
  - Reuse existing window/display resolution helpers where they provide live geometry.
  - Add narrow helpers for live geometry the freshness checker cannot read through existing APIs.

- CLI coordinate commands:
  - `Sources/ScreenCommander/CLI/ClickCommand.swift`
  - `Sources/ScreenCommander/CLI/ScrollCommand.swift`
  - `Sources/ScreenCommander/CLI/DragCommand.swift`
  - `Sources/ScreenCommander/CLI/MoveCommand.swift`
  - Add `--strict-metadata`.
  - Thread that flag into the corresponding request model.
  - Ensure JSON output includes the freshness result.

- `Sources/ScreenCommander/MCP/MCPToolRegistry.swift`
  - Add the same strict freshness argument to coordinate tools.
  - Keep the default as advisory.
  - Include freshness result fields in tool responses through the existing result models.

- Tests
  - Add fake freshness checker coverage in engine tests.
  - Add stale-display metadata coverage.
  - Add stale-window metadata coverage.
  - Add strict-mode failure coverage.
  - Add non-strict stale metadata coverage proving the action still runs and reports freshness.

- `README.md`
  - Document the advisory freshness field.
  - Document the strict freshness flag.
  - Tell users to recapture when freshness is stale.

- `SKILL.md`
  - Tell agents to treat stale freshness as a signal to recapture before continuing a coordinate chain.

- `docs/json-output-schema.md`
  - Document `metadataFreshness`.
  - Document `stale_metadata`.

### Acceptance Checks

- Coordinate action JSON includes freshness info when metadata was used.
- Non-strict stale metadata still performs the action.
- Strict stale metadata fails before injection.
- Unknown freshness is represented distinctly from fresh and stale.
- AX-only element workflows are unaffected.
- `swift test` passes.

## 3. Frame Diff Tuning

### Intent

Keep the existing frame diff defaults and allow callers to tune sensitivity when checking small or subtle UI changes.

### Product Contract

- Default grid remains `64x64`.
- Default threshold remains `0.04`.
- CLI callers can override grid and threshold.
- Invalid values fail with `invalid_arguments`.

### File Plan

- `Sources/ScreenCommander/Capture/FrameDiff.swift`
  - Add `FrameDiffConfig`.
  - Store grid size and threshold in the config.
  - Keep defaults equal to current behavior.
  - Validate grid size is positive and bounded.
  - Validate threshold is within a sane closed range.
  - Keep the compare implementation behavior unchanged when using defaults.

- `Sources/ScreenCommander/CLI/RootCommand.swift`
  - Update `CommandRuntime.frameDiff` to accept `FrameDiffConfig`.
  - Keep `--no-diff` behavior unchanged.
  - Return the same `FrameDiffResult` shape.

- CLI action commands:
  - `Sources/ScreenCommander/CLI/ClickCommand.swift`
  - `Sources/ScreenCommander/CLI/TypeCommand.swift`
  - `Sources/ScreenCommander/CLI/KeyCommand.swift`
  - `Sources/ScreenCommander/CLI/KeysCommand.swift`
  - `Sources/ScreenCommander/CLI/ScrollCommand.swift`
  - `Sources/ScreenCommander/CLI/DragCommand.swift`
  - `Sources/ScreenCommander/CLI/MoveCommand.swift`
  - Add `--diff-grid`.
  - Add `--diff-threshold`.
  - Validate once and pass a config into `CommandRuntime.frameDiff`.

- `Sources/ScreenCommander/CLI/SequenceCommand.swift`
  - Support diff config at the sequence command level.
  - Apply that config consistently to each step that captures before/after screenshots.

- `Sources/ScreenCommander/Persistence/Models.swift`
  - Keep result models unchanged for this cycle.
  - Do not add effective config fields to action output.

- Tests
  - Add unit coverage for config validation.
  - Add tests proving default config maps to current `64x64 / 0.04` behavior.
  - Add command/runtime coverage proving overrides reach `FrameDiff.compare`.
  - Add invalid value tests.

- `README.md`
  - Document `--diff-grid`.
  - Document `--diff-threshold`.
  - Keep default behavior examples unchanged.

- `SKILL.md`
  - Add short guidance for raising grid size or lowering threshold when checking small UI changes.

- `docs/json-output-schema.md`
  - Leave unchanged for frame diff tuning because output shape stays the same.

### Acceptance Checks

- Existing default diff tests still pass.
- Existing action output remains compatible by default.
- CLI override flags change the frame diff calculation.
- Invalid tuning values fail clearly.
- `swift test` passes.

## 4. Documentation Consolidation

### Intent

Make the documentation set describe the shipped tool consistently and remove legacy planning artifacts that read as active sources of truth.

### Documentation Ownership

- `README.md` is the GitHub-facing product README and current command contract.
- `SKILL.md` is the operator runbook for agents using the CLI.
- `AGENTS.md` is repo-local contributor and agent guidance.
- `docs/json-output-schema.md` is the machine-readable output contract.
- `docs/follow-up-design-issues.md` is the temporary implementation spec for this cleanup cycle.

### File Plan

- `README.md`
  - Keep current installation, command, output, MCP, and troubleshooting docs.
  - Remove stale references to old implementation phases or future-tense shipped work.
  - Add current click/focus behavior, MCP scheduling, metadata freshness, and frame diff tuning as the code changes land.

- `SKILL.md`
  - Keep concise operational workflows.
  - Ensure examples match the current CLI surface.
  - Add current guidance for MCP serial chaining, freshness interpretation, and diff tuning as the code changes land.

- `AGENTS.md`
  - Keep repo workflow instructions only.
  - Remove claims that `INIT.md` is the active source of truth once `INIT.md` is deleted.
  - Point implementation tracking to this follow-up spec while the cleanup cycle is active.

- `docs/json-output-schema.md`
  - Keep and update as schema changes land.
  - Document new error codes and result fields introduced by this plan.

- `docs/capability-plan.md`
  - Delete. It is legacy planning.

- `INIT.md`
  - Delete. It is the original implementation tracker and no longer owns current scope.

### Verification Plan

- Run `rg "capability-plan|INIT.md|future|planned|TODO"` across docs after cleanup.
- Run `rg "double|focus|dependsOn|metadataFreshness|diff"` across docs to confirm current semantics are described in the right place.
- Spot-check `swift run screencommander --help` if CLI flags changed.

### Acceptance Checks

- No shipped command is described as future work.
- No deleted legacy doc is referenced as the active source of truth.
- README, SKILL, and AGENTS have distinct responsibilities.
- Schema docs reflect any result or error changes introduced by this plan.
