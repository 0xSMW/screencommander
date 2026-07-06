# screencommander Capability Spec

Detailed implementation spec for the next capability wave. Scoped 2026-07-06, refined
2026-07-06 against the codebase at `ef4beb3`. Structured as independent **work packages
(WP1–WP8)** with explicit dependencies, file-conflict notes, and agent assignments so it
can be executed as a dynamic multi-agent workflow.

---

## Codebase ground truth (read this before implementing any WP)

SwiftPM package, swift-tools 5.10, **macOS 14+**, executable target `ScreenCommander`
(product `screencommander`), dependency `swift-argument-parser` 1.3+. Build with
`swift build`, test with `swift test` (XCTest only — no Swift Testing). Frameworks
linked: ScreenCaptureKit, ApplicationServices, CoreGraphics, ImageIO,
UniformTypeIdentifiers.

Architecture (all under `Sources/ScreenCommander/`):

- **`CLI/RootCommand.swift`** — root `ParsableCommand`; subcommand registration at
  `RootCommand.configuration.subcommands` (~line 48); `OutputFormat`/`OutputOptions`
  (per-command `--json` > root `--output json` > `SCREENCOMMANDER_OUTPUT` env);
  **`CommandRuntime`** enum with `engine` (shared `ScreenCommanderEngine.live()`),
  `emitJSON(command:result:compact:)`, `emitErrorJSON`, `mapError`,
  `captureActionScreenshot(prefix:)`; envelope types `CommandEnvelope`,
  `ErrorEnvelope`/`ErrorDetail`, `ActionResultEnvelope { action, preshot, postshot }`,
  `ActionScreenshotResult { imagePath, metadataPath }`; `AsyncBridge.run` (semaphore
  bridge for async engine calls inside sync `run()`).
- **`Core/ScreenCommanderEngine.swift`** — orchestrator with constructor-injected
  protocols: `PermissionChecking`, `DisplayResolving`, `ScreenCapturing`,
  `ImageWriting`, `SnapshotMetadataStoring`, `CoordinateMapper` (concrete struct),
  `MouseControlling`, `KeyboardControlling`, `CaptureRetentionManaging`, `StatePaths`.
  `static func live()` wires production impls. Methods: `screenshot`, `click`, `type`,
  `key`, `keys`, `cleanup` — each checks its permission first.
- **`Core/Errors.swift`** — `ScreenCommanderError` with stable `exitCode` (Int32) and
  `stableCode` (snake_case, used in JSON `error.code`). Existing codes: 10/11
  permissions, 20/21 capture/write, 30 metadata, 40/41 coordinates, 50 input
  synthesis, 60 invalid arguments.
- **`Core/CoordinateMapping.swift`** — `CoordinateSpace` (`.pixels|.points|.normalized`),
  `CoordinateMapper.map(x:y:space:metadata:) -> ResolvedCoordinate
  { inputX, inputY, space, globalX, globalY }`. Global point = display origin (points,
  top-left) + per-space delta; pixels divide by `pointPixelScale`.
- **`Core/Displays.swift`** — `DisplayResolving.resolveDisplay(identifier:)` via
  `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`;
  returns `ResolvedDisplay { displayID, displayFramePoints, scDisplay }`.
- **`Capture/`** — `ScreenCapturing.capture(display:includeCursor:) ->
  CapturedScreenshot { image: CGImage, displayID, displayBoundsPoints,
  pointPixelScale }` via `SCScreenshotManager.captureImage`; `ImageWriting.write` via
  ImageIO; `ImageFormat` (.png/.jpeg).
- **`Persistence/Models.swift`** — DTOs incl. `ScreenshotMetadata
  { capturedAtISO8601, displayID, displayBoundsPoints: RectD, imageSizePixels: SizeD,
  pointPixelScale, imagePath }` (property names = JSON keys; `RectD = {x,y,w,h}`,
  `SizeD = {w,h}`). `SnapshotMetadataStore` writes `<image>.json` sidecars and
  `~/Library/Caches/screencommander/last-screenshot.json` (only the `screenshot`
  command updates "last"; pre/post shots pass `updateLastMetadata: false`).
- **`Input/MouseController.swift`** — `MouseControlling.click(at:button:doubleClick:
  primeClick:humanLike:)`; posts `CGEvent`s to `.cghidEventTap` from a
  `.hidSystemState` source. `MouseButtonChoice` = `.left|.right` today.
- **`CLI/SequenceCommand.swift`** — decodes `SequenceFile { steps: [SequenceStep] }`;
  `SequenceStep` is a custom-Decodable enum keyed by exactly one of
  `click`/`type`/`key` per step object.
- **Tests** (`Tests/ScreenCommanderTests/`, 47 XCTest methods, 8 files) — hand-written
  fakes for every protocol at the top of `ScreenCommanderEngineTests.swift`
  (`FakeMouseController` records `ClickCall` structs, etc.); `StatePaths(environment:
  ["SCREENCOMMANDER_STATE_DIR": tempDir])` isolates state; tests needing live displays
  use `XCTSkip`.

JSON contract (`docs/json-output-schema.md`): exactly one object on stdout —
`{status: "ok", command, result, exitCode: 0}` or `{status: "error", command,
error: {code, message}, exitCode}`. Action commands wrap results in
`result: { action, preshot, postshot }`. **No schema-version field exists**; additions
must be backward compatible (new optional fields only).

**Definition of done for every WP** (the per-WP acceptance criteria assume these):

1. `swift build` and `swift test` pass; new engine-level behavior has XCTest coverage
   using the existing fake-injection pattern (extend fakes, don't add mocking libs).
2. New/changed JSON documented in `docs/json-output-schema.md`; new exit codes in
   `Core/Errors.swift` **and** the README exit-code table.
3. New subcommands registered in `RootCommand.configuration.subcommands` and documented
   in README (usage + Behavior list) and SKILL.md (if agent-relevant).
4. Human output stays one-glance readable; JSON stays the scripting surface.
5. No third-party dependencies beyond swift-argument-parser.

**Live-verification caveat:** unit tests run against fakes and pass headless. Real
CGEvent/AX/ScreenCaptureKit behavior requires the built binary to hold Accessibility
and Screen Recording TCC grants — implementation agents must NOT assume they can grant
these. Each wave ends with a **manual smoke checklist** run by Stephen (listed per WP).

---

## Reserved identifiers (allocated now so parallel agents don't collide)

New stable error codes / exit codes (extend `ScreenCommanderError`):

| exitCode | stableCode | Introduced by | Meaning |
|---|---|---|---|
| 70 | `element_not_found` | WP5 | AX element matching `--element`/`--element-id` not found |
| 71 | `ax_tree_unavailable` | WP4 | Target app exposes no usable AX tree |
| 72 | `element_not_actionable` | WP5 | Element found but disabled / action unsupported (`--strict`) |
| 73 | `observe_timeout` | WP7 | `observe --until` predicate unmet within `--timeout-ms` |
| 80 | `window_not_found` | WP2 | `--window` id/title matched nothing |
| 81 | `app_not_found` | WP2 | `--app` name/pid matched no running app |

New JSON fields (all optional/additive): `ActionResultEnvelope.diff` (WP3),
`ActionResultEnvelope.action.deliveryMethod` + `.requestedVia` (WP5),
`ScreenshotMetadata.windowID` + `.windowBoundsPoints` (WP2).

`--via` values: `ax` | `pid` | `global` (WP5). Element ids: dot-joined child-index
paths from the app element, e.g. `"0.3.2"` (WP4).

---

## Work packages

### WP1 — Input primitives: `scroll`, `drag`, `move`, richer `click`

**Goal:** agents can read below the fold, drag, hover, and modifier-click.
**Depends on:** nothing. **Parallel-safe:** yes (worktree).
**Agent profile:** clear-spec mechanical implementation → **gpt-5.5 via codex wrapper**
(sonnet-4.6 low-effort wrapper running `codex exec`); review by opus-4.8.

Spec:

- `scroll <x> <y> --dy <n> [--dx <n>] [--unit lines|pixels] [--space ...] [--meta ...]`
  — map coordinates exactly like `click`; move cursor to point, then post
  `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`
  (wheel1 = vertical, wheel2 = horizontal; `.line` vs `.pixel` units; default
  `--unit lines`). At least one of `--dx/--dy` must be nonzero.
- `drag <x1> <y1> <x2> <y2> [--button left|right] [--steps N=12] [--duration-ms N=300]`
  — `mouseDown` at start → interpolated `.leftMouseDragged` moves (`steps` intermediate
  events spread over `duration-ms` with `usleep`) → `mouseUp` at end. Both endpoints
  mapped through the same metadata/space.
- `move <x> <y> [--dwell-ms N=0]` — single `.mouseMoved` post; sleep `dwell-ms` after.
- `click` additions: `--button middle` (extend `MouseButtonChoice` with `.middle` →
  `.center` CGMouseButton, `.otherMouseDown/.otherMouseUp`); `--modifiers
  cmd,shift,option,ctrl` (parse to `CGEventFlags`, set on every mouse event of the
  click); `--triple` (clickState 3; mutually exclusive with `--double`).
- `sequence`: new step keys `scroll`, `drag`, `move`, `sleep` (payload structs mirror
  the CLI options; `sleep: { ms: Int }`), added to the exactly-one-key decoding in
  `SequenceStep.init(from:)`.
- Engine: new methods `scroll(_:)`, `drag(_:)`, `move(_:)` with request/result DTOs in
  `Persistence/Models.swift`; `MouseControlling` gains
  `scroll(at:dx:dy:unit:) throws`, `drag(from:to:button:steps:durationMS:) throws`,
  `move(to:) throws`; all check `ensureAccessibilityAccess` first.
- JSON action shapes: `scroll.action { resolved, dx, dy, unit }`;
  `drag.action { from, to, button, steps, durationMilliseconds }` (from/to are
  `ResolvedCoordinate`s); `move.action { resolved, dwellMilliseconds }` — all wrapped
  in the standard `ActionResultEnvelope` with pre/post shots.

Files touched: `Input/MouseController.swift`, new `CLI/ScrollCommand.swift` /
`DragCommand.swift` / `MoveCommand.swift`, `CLI/ClickCommand.swift`,
`CLI/SequenceCommand.swift`, `Persistence/Models.swift`, `CLI/RootCommand.swift`
(subcommand list), docs.

Acceptance: engine tests via extended `FakeMouseController` (records scroll/drag/move
calls incl. interpolation params); modifier/`--triple` parse tests; sequence decoding
tests for the four new step types. Manual smoke: scroll a Finder window, drag a file,
hover a dock item, cmd-click a Safari link.

### WP2 — Window/app targeting: `windows`, `screenshot --window`, `focus`

**Goal:** per-window capture and app-scoped operations instead of whole-display.
**Depends on:** nothing. **Parallel-safe:** yes (worktree).
**Agent profile:** mostly mechanical, small schema-design surface → **gpt-5.5 via
codex wrapper**; review by opus-4.8 (metadata/mapping changes are correctness-critical).

Spec:

- New `Core/Targets.swift` with `TargetResolving` protocol (production impl backed by
  `SCShareableContent` + `NSWorkspace`/`NSRunningApplication`):
  - `resolveApp(identifier: String) async throws -> ResolvedApp { pid, name,
    bundleID? }` — identifier is pid (numeric) or case-insensitive app-name
    prefix/exact match; ambiguous prefix → `invalid_arguments` listing candidates;
    no match → `app_not_found` (81).
  - `listWindows(app: ResolvedApp?) async throws -> [WindowInfo { windowID, title,
    appName, pid, boundsPoints: RectD, isOnScreen, layer }]` from
    `SCShareableContent.windows` (`SCWindow`).
  - `resolveWindow(identifier: String) async throws -> (SCWindow, WindowInfo)` —
    numeric id, or app-name (frontmost window of that app); miss → `window_not_found`
    (80).
- `windows [--app <name|pid>] [--json]` — lists `WindowInfo` rows.
- `screenshot --window <id|app-name>` — capture via
  `SCContentFilter(desktopIndependentWindow:)`; `ScreenshotMetadata` gains optional
  `windowID: UInt32?` and `windowBoundsPoints: RectD?`; **`CoordinateMapper.map` uses
  `windowBoundsPoints` as the bounds rect when present** (window-relative pixels →
  global points), leaving display-scoped behavior byte-identical when absent.
- `focus --app <name|pid>` — `NSRunningApplication.activate(options:)`; report prior
  and new frontmost app in the result. (AX-based raising of a specific window is
  deferred to WP5, which owns AX actions.)

Files: new `Core/Targets.swift`, `Capture/ScreenCaptureKitCapturer.swift` (window
filter path — add a `capture(window:includeCursor:)` to `ScreenCapturing` or a filter
enum), `Persistence/Models.swift` (metadata fields), `Core/CoordinateMapping.swift`,
new `CLI/WindowsCommand.swift` / `FocusCommand.swift`, `CLI/ScreenshotCommand.swift`,
`Core/Errors.swift` (80/81), `CLI/RootCommand.swift`, docs.

Acceptance: `CoordinateMapperTests` extended for window-bounds metadata (both spaces,
scale 2.0, secondary-display-style nonzero origins); metadata round-trip test with the
new optional fields; old sidecars (without the fields) still decode. Manual smoke:
`windows`, capture one Safari window on a cluttered desktop, click a pixel coordinate
from that window capture and confirm it lands.

### WP3 — Frame diff between preshot/postshot

**Goal:** agents branch on "did the action change anything" without vision tokens.
**Depends on:** nothing. **Parallel-safe:** yes (worktree); touches
`CLI/RootCommand.swift` so expect a small integration merge with WP1/WP2.
**Agent profile:** self-contained algorithm → **gpt-5.5 via codex wrapper**.

Spec:

- New `Capture/FrameDiff.swift`:
  `FrameDiff.compare(_ pre: CGImage, _ post: CGImage, grid: Int = 64,
  threshold: Double = 0.04) -> FrameDiffResult { changedFraction: Double,
  changedRegion: RectD? }` — draw both images into `grid×grid` RGBA8 CGContexts,
  per-cell mean channel delta > threshold ⇒ changed; `changedFraction` = changed
  cells / total; `changedRegion` = union bbox of changed cells expanded back to
  **postshot pixel space**; `nil` region when fraction is 0. Dimension mismatch ⇒
  return `changedFraction: 1.0`, full-image region (don't throw).
- `CommandRuntime.captureActionScreenshot` returns the captured `CGImage` alongside
  paths (internal type change; `ActionScreenshotResult` on the wire is unchanged);
  action commands diff pre/post in-memory and attach
  `ActionResultEnvelope.diff: FrameDiffResult?`.
- `--no-diff` flag on click/type/key/keys/scroll/drag/move + sequence steps; diff
  auto-skipped when either shot is missing (`--no-preshot`/`--no-postshot`/capture
  failure). Human output: one line, e.g. `diff: 3.1% changed in (812,40 1024×310)`.
- Saved captures remain full quality — downsampling is comparison-only, in memory.

Files: new `Capture/FrameDiff.swift` (+ `FrameDiffTests.swift`),
`CLI/RootCommand.swift` (`captureActionScreenshot`, `ActionResultEnvelope`), each
action command (flag plumbing), docs.

Acceptance: unit tests with synthetic CGImages — identical images ⇒ 0.0/nil; single
changed block ⇒ region bbox covers it and nothing more (±1 cell); full change ⇒ 1.0;
mismatched sizes ⇒ 1.0. Manual smoke: one live click showing the diff line.

### WP4 — AX read core: `AX/` module + `elements` command

**Goal:** ground-truth UI structure and text-only screen reading. This is the
foundation WP5 and WP7 build on — its internal API quality matters most.
**Depends on:** WP2 (`TargetResolving.resolveApp`). If run in parallel with WP2, code
against the `ResolvedApp` shape specified above and let the integrator reconcile.
**Parallel-safe:** yes (worktree; new files almost exclusively).
**Agent profile:** hardest package — CF memory management, API design consumed by
agents (taste-critical) → **fable-5**; independent review by opus-4.8 + codex pass.

Spec:

- New `Sources/ScreenCommander/AX/`:
  - `AXElement.swift` — value-typed wrapper over `AXUIElement` with typed accessors:
    `role`, `subrole`, `title`, `value` (string-coerced), `axDescription`, `help`,
    `isEnabled`, `isFocused`, `frame: CGRect?` (from `kAXFrameAttribute`, falling back
    to position+size `AXValue`s), `children`, `actionNames: [String]`, and
    `stringForRange` via `AXUIElementCopyParameterizedAttributeValue`
    (`kAXStringForRangeParameterizedAttribute`) for large text. All getters return
    optionals; AX errors never crash a traversal.
  - `AXTreeWalker.swift` — DFS with `maxDepth` (default 40), `maxElements` (default
    2000), optional role filter and visible-only filter (frame intersects window
    bounds). Emits `AXElementRecord`.
  - `AXElementRecord` (Codable): `{ id: String /* child-index path, "0.3.2" */, role,
    subrole?, title?, value?, valueTruncated: Bool?, description?, enabled: Bool,
    focused: Bool?, actions: [String], boundsPoints: RectD?, boundsPixels: RectD? }`.
    `value` truncated to `--max-value-length` (default 200).
  - `AXReader.swift` — `AccessibilityReading` protocol (so engine tests can fake it):
    `tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult`,
    `elementAt(globalPoint: CGPoint) throws -> AXElementRecord?`,
    `resolve(id: String, app: ResolvedApp) throws -> AXElement`. Production impl
    creates `AXUIElementCreateApplication(pid)`.
  - Electron/Chromium priming: before traversal, set `AXManualAccessibility = true`
    (and `AXEnhancedUserInterface = true` if the former is unsupported) on the app
    element; record which was set in the result (`axPrimed: Bool`) and restore
    `AXEnhancedUserInterface`'s prior value after (it has known window-manager side
    effects). Empty/one-node tree after priming ⇒ `ax_tree_unavailable` (71).
- `elements [--app <name|pid>] [--window-id N] [--all-windows] [--text]
  [--max-depth N] [--max-elements N] [--roles r1,r2] [--visible-only] [--json]` —
  default target: frontmost app (`NSWorkspace.shared.frontmostApplication`).
  - `boundsPixels`: inverse of `CoordinateMapper` against
    `last-screenshot.json` — `px = (globalPoint − metadataBounds.origin) × scale` —
    populated only when the element lies within that metadata's bounds; omitted (with
    no error) when no metadata exists. `boundsPoints` always present when AX reports a
    frame. Result carries the `metadataPath` used, or null.
  - `--text` mode: indented tree-order lines `role "title": value`, skipping records
    with no text content; human output **and** the string payload of the JSON result
    (`result.text`). Traversal of a focused window should stay in the 30–80 ms range —
    use `AXUIElementCopyMultipleAttributeValues` to batch per-element reads.
- Engine: `elements(_ ElementsRequest) throws -> ElementsResult { app, windowID?,
  metadataPath?, axPrimed, truncated: Bool /* hit maxElements */, elements: [...] }`
  behind `AccessibilityReading` injection; checks `ensureAccessibilityAccess` first.

Files: new `AX/` module (4 files), `Core/ScreenCommanderEngine.swift` (inject
`AccessibilityReading`), new `CLI/ElementsCommand.swift`, `Core/Errors.swift` (71),
`Persistence/Models.swift`, `CLI/RootCommand.swift`, docs.

Acceptance: engine tests with a `FakeAccessibilityReader`; id-path resolution tests;
pixel-mapping tests mirroring `CoordinateMapperTests` (scale 2, offset display,
element outside metadata bounds ⇒ nil pixels); `--text` rendering tests from canned
records; truncation marker test. Manual smoke: `elements --app Safari --text` on a
real page; `elements` on an Electron app (VS Code) confirming priming; System
Settings tree.

### WP5 — Pointer-free input: `click --element`, `--via ax|pid|global`

**Goal:** act on apps without stealing the user's cursor ("second mouse").
**Depends on:** WP4 (AX module), WP1 (MouseController surface).
**Parallel-safe with WP7:** yes — WP5 owns `AX/AXActions.swift`, WP7 owns
`AX/AXObserverStream.swift`; both extend the engine (integration merge expected).
**Agent profile:** subtle platform behavior (CGEventPostToPid quirks, tier fallback
semantics) → **fable-5**; review opus-4.8.

Spec — a tiered actuator, tried in order, with the outcome reported:

1. **Tier `ax`** — new `AX/AXActions.swift`: `AXActionPerforming` protocol with
   `perform(action: String, on: AXElement) throws` (`AXUIElementPerformAction`:
   `AXPress`, `AXShowMenu`, `AXConfirm`, `AXIncrement`/`AXDecrement`) and
   `setValue(_ value: String, on: AXElement) throws`
   (`AXUIElementSetAttributeValue` for `AXValue`, `AXSelectedTextRange`, `AXFocused`).
   Coordinate-free, works on background apps, immune to concurrent user mouse
   movement.
2. **Tier `pid`** — extend `MouseControlling` (or a sibling `TargetedMouseControlling`)
   with pid-targeted variants: build the same CGEvents but post with
   `CGEventPostToPid`. Coordinates remain screen-space. Known caveat: some apps ignore
   posted events while unfocused — the tier succeeds if posting succeeds; effect
   detection is the caller's job (frame diff / observe).
3. **Tier `global`** — existing `CGEventPost(.cghidEventTap)` path, unchanged. Moves
   the real cursor.

CLI surface:

- `click --element "<title/label substring>"` or `--element-id <id>` (+ `--app` from
  WP2 resolution; `--role` to disambiguate). Resolution happens **fresh at click
  time** via `AccessibilityReading` — never trust stale ids across UI changes. Not
  found ⇒ `element_not_found` (70). Found-but-disabled or action unsupported ⇒ tier
  falls through; under `--strict` ⇒ `element_not_actionable` (72).
- `--via ax|pid|global` forces a tier (no fallback, `--strict` implied).
  Default policy: coordinate clicks keep today's behavior (`global`); element clicks
  try `ax → pid → global`. `--no-cursor` restricts fallback to `ax → pid` (never
  moves the pointer).
- Envelope: `action.requestedVia` (what was asked) and `action.deliveryMethod`
  (`"ax"|"pid"|"global"` — what actually ran), plus `action.element` (the resolved
  `AXElementRecord`) for element clicks. Downgrades are recorded, not errors, unless
  `--strict`.
- Same options on `scroll` (pid tier only — no AX scroll action) and `type`
  (`--element` sets `AXValue` directly at tier `ax`; falls back to focus + existing
  keyboard path).
- Sequence steps gain optional `element`/`via` fields on click/type steps.
- Pre-click validation: for coordinate clicks with `--verify-target`, hit-test via
  `AccessibilityReading.elementAt(globalPoint:)` and include the hit element in the
  result.

Files: new `AX/AXActions.swift`, `Input/MouseController.swift`,
`Core/ScreenCommanderEngine.swift` (tier orchestration lives in the engine, not the
CLI), `CLI/ClickCommand.swift` / `TypeCommand.swift` / `ScrollCommand.swift`,
`CLI/SequenceCommand.swift`, `Core/Errors.swift` (70/72), docs.

Acceptance: engine tests with fakes proving tier order, forced-tier, `--no-cursor`
never reaching global, downgrade recording, `--strict` failure codes, fresh-resolution
(fake reader returns a different element on the second call). Manual smoke:
`click --element "General" --app "System Settings" --no-cursor` while continuously
moving the real mouse; pid-tier click on a background TextEdit window; confirm the
cursor never moved.

### WP7 — Real-time observation: `observe` (AXObserver event stream)

**Goal:** push-based UI change feed; agents block on outcomes instead of
capture-and-look polling. (Numbered 7 to keep prior item numbering; runs in wave 2.)
**Depends on:** WP4 (AX module, `AXElementRecord`), WP2 (app resolution).
**Parallel-safe with WP5:** yes (see WP5 note).
**Agent profile:** run-loop/lifetime management + streaming protocol design →
**opus-4.8**; fable-5 review.

Spec:

- New `AX/AXObserverStream.swift`: wraps `AXObserverCreate` +
  `AXObserverAddNotification`; runs the observer's run-loop source; maps
  notifications ⇒ event records. Notification set (selected via `--events`, default
  all): `value` (`kAXValueChangedNotification`), `focus`
  (`kAXFocusedUIElementChangedNotification`), `window` (`kAXWindowCreated`,
  `kAXWindowMoved`, `kAXWindowResized`, `kAXTitleChangedNotification`), `destroy`
  (`kAXUIElementDestroyedNotification`), `app` (NSWorkspace launch/activate/
  terminate notifications, observed alongside AX).
- `observe --app <name|pid> [--events value,focus,window,destroy,app]
  [--timeout-ms N] [--until '<predicate>'] [--json]` — streams **NDJSON, one event per
  line** to stdout (this command ignores pretty/compact — always one-line JSON):
  `{ ts: ISO8601, event: "value_changed"|..., app: { pid, name },
  element: AXElementRecord? }`. Runs until SIGINT (exit 0), `--timeout-ms` elapsed
  (exit 0 if plain observe; **73** if `--until` unmet), or `--until` matched (exit 0,
  final line `{ matched: true, element: ... }`).
- `--until` predicate mini-DSL, whitespace-joined conjunctions:
  `role=AXButton title~=Save` (`=` exact, `~=` case-insensitive contains; keys:
  `role`, `title`, `value`, `id`). The matcher checks each incoming event's element
  AND does one initial tree scan so already-true conditions return immediately.
- Testability: predicate parser and event-record serialization are pure and fully
  unit-tested; the observer wrapper hides behind a protocol so the engine/command can
  be tested with a scripted fake event source.
- Design note for WP8: structure the stream as an internal
  `AsyncStream<ObservedEvent>` so the MCP server can hold observers warm and answer
  "what changed since last call" without re-registering.

Files: new `AX/AXObserverStream.swift`, new `CLI/ObserveCommand.swift`,
`Core/Errors.swift` (73), `Core/ScreenCommanderEngine.swift` or a dedicated
`ObserveService`, docs (incl. NDJSON event schema in `docs/json-output-schema.md`).

Acceptance: predicate parser tests (each operator, conjunction, malformed ⇒
`invalid_arguments`); fake-source tests for filtering, `--until` match, initial-scan
match, timeout ⇒ 73. Manual smoke: `observe --app TextEdit --events value` while
typing; `observe --app Finder --until 'role=AXWindow title~=Downloads'
--timeout-ms 10000` then opening Downloads.

### WP8 — MCP server / daemon mode: `serve --mcp`

**Goal:** persistent, warm integration surface; screenshots delivered as in-band image
content instead of file paths.
**Depends on:** WP1–WP5, WP7 (exposes the full tool set in one pass).
**Parallel-safe:** runs alone in wave 3.
**Agent profile:** protocol implementation + agent-facing tool API design →
**opus-4.8**; fable-5 review; consult current MCP spec docs rather than memory for the
protocol revision.

Spec:

- `screencommander serve --mcp` — **stdio transport, newline-delimited JSON-RPC 2.0**
  per the MCP spec (note: MCP stdio framing is line-delimited JSON, not LSP
  `Content-Length` headers). Hand-rolled: a read-loop decoding requests, a dispatch
  table, `initialize` / `tools/list` / `tools/call` methods. No third-party deps.
- Tools mirror the engine 1:1: `screenshot`, `click`, `type`, `key`, `keys`, `scroll`,
  `drag`, `move`, `elements`, `windows`, `focus`, `observe_wait` (wraps
  `--until`+timeout as a single call), `doctor`, `cleanup`. Input schemas mirror CLI
  options; results are the **same JSON envelopes** the CLI emits (as
  `structuredContent` plus a text block), so the schema doc covers both surfaces.
- `screenshot` additionally returns an MCP **image content block** (base64 PNG,
  full quality) so callers get pixels in-band; metadata object alongside.
- One warm `ScreenCommanderEngine` instance; cache the `SCShareableContent`
  enumeration with a short TTL (~2 s) to cut the 100–300 ms per-call cost; permission
  state checked once at startup + surfaced via `doctor`.
- Warm-observer stretch goal (only if WP7's `AsyncStream` landed cleanly): a
  `changes_since` tool backed by per-app observers started on first use.
- README gains a `claude mcp add screencommander -- screencommander serve --mcp`
  snippet; SKILL.md notes when to prefer MCP over the CLI.

Files: new `MCP/` module (`Server.swift`, `JSONRPC.swift`, `ToolRegistry.swift`),
`CLI/ServeCommand.swift`, `CLI/RootCommand.swift`, docs.

Acceptance: JSON-RPC codec unit tests (parse/serialize, unknown method ⇒ error
object); tool-registry tests with a fake engine (every tool dispatches, schemas
validate); a golden `initialize` → `tools/list` → `tools/call(doctor)` transcript test
driving the server loop over in-memory pipes. Manual smoke: `claude mcp add` locally,
take a screenshot through MCP, element-click through MCP.

---

## Dependency graph and wave plan

```
WP1 input ──────────────┐
WP2 windows ──► WP4 AX ─┼─► WP5 pointer-free ─┐
WP3 diff ───────────────┤                      ├─► WP8 MCP
                        └─► WP7 observe ───────┘
```

| Wave | Packages (parallel) | Isolation | Gate before next wave |
|---|---|---|---|
| 1 | WP1, WP2, WP3, WP4 | one worktree each | Integrator merges (order WP1→WP2→WP3→WP4); full `swift test`; review pass; **manual smoke checklist (Stephen — TCC)** |
| 2 | WP5, WP7 | one worktree each | Same: merge, test, review, manual smoke |
| 3 | WP8 | main branch | Final review + docs-consistency pass + manual smoke |

Known conflict hotspots for the integrator: `CLI/RootCommand.swift` (subcommand
registration, `captureActionScreenshot` signature from WP3, `ActionResultEnvelope`
fields from WP3/WP5), `Persistence/Models.swift` (DTOs from WP1/WP2/WP4),
`Core/Errors.swift` (codes are pre-allocated above — merges are additive),
`docs/json-output-schema.md` and README (every WP appends).

## Multi-agent execution notes

Model choices follow `claude.md` (intelligence > taste > cost; escalate without asking
if output misses the bar; never Haiku):

| Role | Model | Notes |
|---|---|---|
| WP1, WP2, WP3 implementation | gpt-5.5 | via codex wrapper (sonnet-4.6 `effort: low` wrapper → `codex exec`); this spec is deliberately complete enough for clear-spec execution |
| WP4, WP5 implementation | fable-5 | CF memory management + agent-facing API design (taste ≥ 7 required) |
| WP7, WP8 implementation | opus-4.8 | run-loop/protocol work; taste 8 for the MCP tool surface |
| Integrator (per wave) | opus-4.8 | merge worktrees in the stated order, resolve hotspots, run full suite |
| Review gate (per wave) | fable-5 | plus an independent `codex review` second pass |
| Docs-consistency pass (wave 3) | opus-4.8 | README / SKILL.md / json-output-schema.md agree with `--help` output |

Workflow-shape guidance (dynamic workflow):

- **Phase per wave.** Wave 1: four `agent()` calls with `isolation: 'worktree'`, each
  given its WP section verbatim plus the ground-truth and reserved-identifier
  sections. Require structured output: `{ branchOrWorktree, filesTouched[],
  testsAdded[], swiftTestPassed: bool, deviations[] }` — a WP agent that must deviate
  from this spec records the deviation rather than silently improvising.
- **Integration is its own agent**, not a merge script: it rebases/merges the wave's
  worktrees in the stated order, reconciles hotspot files, and must end with a clean
  `swift build && swift test`.
- **Review gate** after integration: reviewer agents get the wave diff and this spec;
  findings are adversarially verified before being sent back to a fix-up agent.
- **Manual smoke is a hard stop.** Each wave's per-WP smoke items need live TCC
  grants; pause the workflow and hand Stephen the checklist rather than having agents
  fake it.
- WP text is written to be self-contained (exact types, files, signatures) so
  implementation agents should not need broad re-exploration — point them at specific
  files only.

---

## Appendix — API reference: macOS accessibility & input APIs

All of these are gated by the single Accessibility TCC grant
(`AXIsProcessTrustedWithOptions`) — none require the Screen Recording permission.

| API / Method | Framework | What it gives us |
|---|---|---|
| `AXUIElementCopyAttributeValue` (+ `CopyMultipleAttributeValues`) | ApplicationServices | Read UI tree: `AXRole`, `AXTitle`, `AXValue`, `AXDescription`, `AXFrame` — the text-only screen representation (WP4, WP7) |
| `AXUIElementCopyParameterizedAttributeValue` | ApplicationServices | Ranged text extraction (`AXStringForRange`, text markers) for large documents (WP4) |
| `AXUIElementPerformAction` | ApplicationServices | Coordinate-free "clicks": `AXPress`, `AXShowMenu`, `AXConfirm`, `AXIncrement` (WP5 tier `ax`) |
| `AXUIElementSetAttributeValue` | ApplicationServices | Direct writes: text field values, selection, focus, window position (WP5 tier `ax`) |
| `AXUIElementCopyElementAtPosition` | ApplicationServices | Hit-testing: what element is at (x, y) without capturing pixels (WP5 `--verify-target`) |
| `AXObserverCreate` / `AXObserverAddNotification` | ApplicationServices | Real-time push stream of UI changes — replaces screenshot polling (WP7) |
| `CGEventPostToPid` + `CGEventCreateMouseEvent` | CoreGraphics | "Second mouse": synthetic clicks/scrolls delivered to one app, user's cursor untouched (WP5 tier `pid`) |
| `CGEventPost(.cghidEventTap)` | CoreGraphics | Global synthetic input — moves the real cursor (existing path; WP5 tier `global`) |
| `CGWindowListCopyWindowInfo` | CoreGraphics | Window titles, owners, bounds, layer order without screenshots (WP2 alt path) |
| `SCShareableContent` / `SCContentFilter(desktopIndependentWindow:)` | ScreenCaptureKit | Window/display enumeration and per-window capture (WP2) |
| `NSWorkspace` notifications / `frontmostApplication` | AppKit | App lifecycle events (WP7) and default `elements` target (WP4) |
| `NSRunningApplication.activate` | AppKit | Bring an app to the foreground (WP2 `focus`) |
| `AXIsProcessTrustedWithOptions` | ApplicationServices | Check/prompt for the Accessibility permission gating all of the above (`doctor`) |
| `AXEnhancedUserInterface` / `AXManualAccessibility` | (app-level AX attribute) | Force Chromium/Electron apps to populate their AX tree (WP4 priming) |

**Target architecture:** the AX tree is the primary sensor (traversal + `AXObserver`
deltas), AX actions the primary actuator, `CGEventPostToPid` the secondary actuator,
and screenshots the fallback sensor for AX-opaque apps. Reference implementations:
[AXorcist](https://github.com/steipete/AXorcist/) (Swift query layer),
[ui-events](https://github.com/mediar-ai/ui-events) (Rust AXObserver streaming),
[Multi's remote-control engine writeup](https://multi.app/blog/building-a-macos-remote-control-engine)
(field guide to `CGEventPostToPid` behavior per app).
