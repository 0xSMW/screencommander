# ScreenCommander Spec: Full Hotkeys + Managed Captures Retention

**Date:** 2026-02-21
**Scope status:** Design draft from current codebase and prior ideas
**Branch:** `/Users/stephenwalker/Code/projects/screencommander`

## 1. Objective

Ship two coordinated upgrades:

1. Expand keyboard input so `screencommander key` supports full macOS modifier chords plus special/media/system keys, and add held-sequence key workflows where needed.
2. Move default capture and metadata artifacts into managed state under `~/Library/Caches/screencommander` with automatic 24-hour retention cleanup of managed captures only.

The implementation must preserve the current CLI thinness, keep existing success/error contract stable, and avoid deleting user-provided capture paths.

## 2. Current-state review (what already exists)

### Implemented (and preserved)
- CLI already has `screenshot`, `click`, `type`, `key`, and `sequence` commands in `Sources/ScreenCommander/CLI/*`.
- Core orchestration in `ScreenCommanderEngine` already has request/result structs and command methods for screenshot/click/type/key.
- Mapping and capture logic are already separated in `CoordinateMapping`, `Core/Displays`, `Capture/*`, and `Input/*`.
- Permissions are checked in one place via `Permissions` and surfaced as stable error codes.
- JSON output schema is used by existing commands via `CommandRuntime` envelope.
- `SequenceCommand` already supports click/type/key steps from JSON.

### Gaps to fill for this plan
- `KeyCodes.swift` currently parses chords into `CGKeyCode` only and supports a limited token set.
- No dedicated system key/media key model, and no system-defined event path for those keys.
- No explicit `fn` modifier in model.
- No key hold/step API in `Input/` beyond single `press(chord:)`.
- Default screenshot output path and default `last-screenshot.json` live in current working directory.
- No automatic cleanup policy for generated screenshots/metadata.
- No state path abstraction (`captures/` + `last` path) for consistent multi-cwd behavior.

## 3. Targets and non-goals

### In scope
- Full `key` token coverage (keyboard + function/navigation/pad + common aliases).
- System/media key injection path isolated from normal keyboard chords.
- New `keys` command for explicit press/hold/release sequences and optional named-hotkey convenience.
- Managed captures directory + automatic 24h retention.
- README and AGENTS usage/docs updates.

### Out of scope
- Cross-platform support.
- Runtime UI/frontend surface.
- Fallback capture path for pre-ScreenCaptureKit versions.

## 4. Architecture rules

1. CLI remains argument parsing + output formatting + engine dispatch only.
2. Parsing/sequencing/parsing validation stays in input/core parsing models.
3. Event synthesis logic stays inside `Input/*`.
4. Filesystem policy (paths/retention) is in `Core/Persistence` with explicit injection and no implicit side effects from CLI.
5. Managed capture cleanup only applies under `captures/`.
6. Keep explicit `--out/--meta` behavior unchanged for user-specified absolute and relative paths.

## 5. Hotkey and sequence feature spec

### 5.1 Keyboard token model

#### 5.1.1 Modifier model
- Update `ModifierKey` in `Sources/ScreenCommander/Input/KeyCodes.swift`:
  - Add `.fn` case.
  - `canonicalName` and parsing should continue to render stable aliases (`cmd`, `command`, etc.) with canonical output.
  - Add `flag` path for `.fn` using `CGEventFlags.maskSecondaryFn`.
  - Add optional `keyCode` path (`nil` for `.fn`, existing keycodes for others).

#### 5.1.2 Parsed chord model
- Introduce `ResolvedKey` enum and extend chord parsing:
  - `case keyboard(keyCode: CGKeyCode, token: String)`
  - `case system(SystemKey, token: String)`
- Update `ParsedKeyChord` to carry `ResolvedKey` instead of plain keycode/token pair.
- Keep `normalized` deterministic and stable for existing user input.

#### 5.1.3 Keyboard key token expansion in `KeyCodes.keyMap`
Add tokens for:
- Function keys: `f1`..`f20`
- Navigation: `home`, `end`, `pageup`, `pagedown`
- Keyboard state: `capslock`, `help`
- Numeric pad: `keypad0`..`keypad9`, `keypad+`, `keypad-`, `keypad*`, `keypad/`, `keypad.`, `keypadenter`
- Keep existing keys (letters, digits, punctuation, `enter`, `tab`, `escape`, arrows).

Add or standardize aliases:
- `esc`, `escape`, `return`, `enter`
- `pgup`, `pageup`
- `cmd`, `command`, `meta`
- `opt`, `option`, `alt`
- `ctrl`, `control`

#### 5.1.4 System/media key model
- Add `Sources/ScreenCommander/Input/SystemKeys.swift` with `SystemKey` enum:
  - `volumeUp`, `volumeDown`, `mute`
  - `brightnessUp`, `brightnessDown`
  - `playPause`, `nextTrack`, `previousTrack`
- Add parser path in `KeyCodes.parseChord(_:)`:
  - Try keyboard map first.
  - If missing, resolve system-key map.
  - If missing -> invalid argument error.
- Initial behavior should reject modifier+system key combinations unless explicitly justified (documented parse error).

#### 5.1.5 Input posting behavior
- Extend `KeyboardControlling` protocol:
  - `press(chord:)` remains.
  - `pressSystemKey(_:)` added.
  - `run(sequence:)` added (see section 5.2).
- `KeyboardController.press(chord:)`:
  - If chord key is `.keyboard`, use existing keydown/keyup behavior.
  - If chord key is `.system`, route to system-defined path.
  - For `.fn`, apply modifier flag only; do not post synthetic keydown/up unless framework demands it later.
- Add dedicated internal method for system-defined events to keep semantics isolated and testable.

### 5.2 Sequence model and API

#### 5.2.1 New sequence model
- Add `Sources/ScreenCommander/Input/KeySequence.swift`:
  - `KeyStep` with `.keyDown`, `.keyUp`, `.press`, `.sleep` variants.
  - `KeySequence` wrapper with ordered steps.

#### 5.2.2 Parsing API
- Add parser under `Input/KeySequenceParser.swift` or in model file.
- Token grammar: `down:<token>`, `up:<token>`, `press:<token>`, `sleep:<ms>`.
- Parsing rule:
  - tokens resolve through `KeyCodes.parseChord` into chords or resolved keys.
  - `sleep` duration validated non-negative integer.

#### 5.2.3 KeyboardController sequence execution
- Implement `run(sequence:)` in `KeyboardController`.
- Keep `press(chord:)` as convenience that emits a single press + release only.
- In sequence execution, preserve exact order and release held modifiers explicitly as provided.

#### 5.2.4 CLI and engine wiring
- Add `Sources/ScreenCommander/CLI/KeysCommand.swift`.
- Register command in `RootCommand`.
- Add request/result in engine:
  - `KeysRequest { steps: [String] }`
  - `KeysResult { normalizedSteps: [String] }`
- Engine parses step tokens into `KeySequence` then calls `keyboardController.run(sequence:)`.

### 5.3 Optional convenience named hotkeys
- Add optional `HotkeyCommand` + `HotkeyCatalog` if desired:
  - `mission-control`, `app-next`, `app-prev`
  - Implement using `KeySequence`, not ad-hoc keycode events.
- This is optional and does not replace `key` semantics.

## 6. Managed captures + cleanup feature spec

### 6.1 Path model
- Add `Sources/ScreenCommander/Core/StatePaths.swift`.
- Fields:
  - `stateDirectoryURL`
  - `capturesDirectoryURL`
  - `lastMetadataURL`
- Defaults:
  - `stateDirectoryURL = ~/Library/Caches/screencommander`
  - `capturesDirectoryURL = stateDirectoryURL/captures`
  - `lastMetadataURL = stateDirectoryURL/last-screenshot.json`
- Read `SCREENCOMMANDER_STATE_DIR` environment variable override if set.

### 6.2 Engine integration
- In `ScreenCommanderEngine`:
  - add `statePaths: StatePaths`
  - inject into dependencies:
    - metadata store (for last path)
    - capture-retention manager (for directory cleanup)
- `ScreenCommanderEngine.live()` constructs state paths once and passes to services.

### 6.3 Default output path behavior
- Update `resolvedImageURL(explicitPath:format:)`:
  - explicit `--out` unchanged.
  - default path -> `statePaths.capturesDirectoryURL/Screenshot-<timestamp>.<ext>`.
- `resolvedMetadataURL` now naturally follows image directory by default.
- Default metadata path in `click`/`type`/`key` workflows to `statePaths.lastMetadataURL` via metadata store injection.

### 6.4 SnapshotMetadataStore update
- Add initializer injection in `Sources/ScreenCommander/Persistence/SnapshotMetadataStore.swift`:
  - `init(fileManager: FileManager = .default, lastMetadataURL: URL)`
- Replace hardcoded `currentDirectoryPath` default for `last-screenshot.json`.
- Keep `save/load` behavior unchanged.

### 6.5 Retention policy
- Add `Sources/ScreenCommander/Persistence/CaptureRetentionManager.swift`.
- Public API:
  - `protocol CaptureRetentionManaging { func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult }`
  - `CleanupResult { deletedCount: Int; deletedBytesApprox: Int64 }`
- Behavior:
  - enumerate managed captures directory.
  - delete only files with `png`, `jpeg`, `json` older than threshold.
  - ignore subdirectories and files outside extension allowlist.
  - ignore explicit user-provided output directories unless they are inside `capturesDirectoryURL`.

### 6.6 Trigger points
- Primary trigger: at beginning of `ScreenCommanderEngine.screenshot(...)` (best effort best match to usage growth).
- Optional secondary: best-effort at command entry for `click/type/key/keys/sequence` with logged warning only on cleanup failure.
- Optional explicit command:
  - `Sources/ScreenCommander/CLI/CleanupCommand.swift`.
  - Engine method `cleanup(_:)`.

### 6.7 Default path migration strategy
- No automatic move of existing files in repository root.
- After migration, `screenshot` writes managed by default, but explicit paths remain valid.
- `last-screenshot.json` lookup defaults to managed path.
- For backwards compatibility, keep support for user passing explicit `--meta`.

## 7. Concrete file change list

### Inputs
- `Sources/ScreenCommander/Input/KeyCodes.swift`
  - modifier model + `fn`
  - `keyMap` expansion
  - new `ParsedKeyChord` + `ResolvedKey`
  - alias parsing updates
- `Sources/ScreenCommander/Input/SystemKeys.swift` *(new)*
- `Sources/ScreenCommander/Input/KeySequence.swift` *(new)*
- `Sources/ScreenCommander/Input/KeySequenceParser.swift` *(new, optional if separate file)*
- `Sources/ScreenCommander/Input/KeyboardController.swift`
  - add sequence run and system-key paths
  - update modifier posting semantics

### Core
- `Sources/ScreenCommander/Core/ScreenCommanderEngine.swift`
  - statePaths injection
  - changed default output and last metadata wiring
  - add `keys(...)` and optional `cleanup(...)`
  - call retention prior to screenshot creation
- `Sources/ScreenCommander/Core/StatePaths.swift` *(new)*

### Persistence
- `Sources/ScreenCommander/Persistence/SnapshotMetadataStore.swift`
  - inject last-metadata URL
- `Sources/ScreenCommander/Persistence/CaptureRetentionManager.swift` *(new)*

### CLI
- `Sources/ScreenCommander/CLI/KeysCommand.swift` *(new)*
- `Sources/ScreenCommander/CLI/RootCommand.swift` add subcommand
- `Sources/ScreenCommander/CLI/ScreenshotCommand.swift`
  - help text reflecting captures dir default
- Optional `Sources/ScreenCommander/CLI/CleanupCommand.swift`
- Optional `Sources/ScreenCommander/CLI/HotkeyCommand.swift` + `Sources/ScreenCommander/Core/HotkeyCatalog.swift` if desired.

### Packaging
- `Package.swift`
  - optional: link `IOKit` if media/system key implementation uses those symbols directly.

## 8. Result/error model updates

### New command result types
- `KeysResult { normalizedSteps: [String] }`
- `CleanupResult { deletedCount: Int; deletedBytesApprox: Int64 }`

### Error handling
- Reuse `ScreenCommanderError` where possible:
  - keep `invalidArguments` for bad tokens/invalid sequence/durations.
  - add metadata/IO failures for retention where needed as `captureFailed` or `metadataFailure`.
- Keep user-facing exit codes stable unless required to add one new code for cleanup failures.

## 9. JSON schema extension plan

- `screencommander key` output unchanged except normalization may now include new tokens.
- `screencommander keys` output includes normalized per-step array for deterministic logs/scripts.
- `screencommander cleanup --json` includes deletion stats and elapsed runtime.

## 10. Documentation updates (required)

### AGENTS.md
- screenshot defaults point to `~/Library/Caches/screencommander/captures/`.
- add examples:
  - `screencommander key "ctrl+up"`
  - `screencommander key "cmd+tab"`
  - `screencommander keys "down:cmd" "press:tab" "press:tab" "up:cmd"`
  - `screencommander key "volumeup"`
- add retention note:
  - managed captures cleanup is automatic for managed directory.
  - explicit paths via `--out/--meta` are not auto-deleted.

### README.md
- update Screenshot section defaults and retention behavior section.
- add Hotkeys section with system/media keys and sequence command examples.

## 11. Verification checkpoints (non-test, design-level)

1. **Keyboard parser parity**
   - known tokens from old behavior still parse identically.
   - new function/navigation/pad/system tokens parse correctly.

2. **Held semantics**
   - `keys` supports `down/press/up/sleep` pipeline.
   - can emulate `cmd` held across repeated `tab` presses.

3. **Managed outputs**
   - default `screenshot` writes to captures folder under state path.
   - metadata sidecars co-located with image.
   - `click` defaults to managed `last-screenshot.json`.

4. **Retention**
   - only managed captures directory is pruned.
   - explicit `--out` outside managed path unaffected.
   - safety: no deletes outside allowlisted extensions.

## 12. Execution phases

### Phase A (P0): Path and storage foundation
- add `StatePaths`
- wire state paths into engine and metadata store
- move defaults to captures dir and last metadata path

### Phase B (P0): Hotkey expansion model
- expand `KeyCodes` and `ModifierKey`
- add `SystemKeys` + `ResolvedKey`
- add system key posting path

### Phase C (P1): Sequence engine
- add `KeySequence` model/parser and `keys` command
- integrate with engine and keyboard controller

### Phase D (P1): Cleanup subsystem
- add retention manager and optional cleanup command
- hook screenshot trigger path and optional explicit invocation

### Phase E (P2): Documentation and polish
- update AGENTS/README/help text
- optional hotkey command/catalog
- compatibility review and migration note section in docs

## 13. Open questions for implementation alignment

1. Should `fn` be allowed as runtime flag only, or should we also allow a fallback explicit low-level key event when needed on specific hardware?
2. For system keys, should initial implementation support only key-down/uptick pair semantics, or include key-down-only + hold-style behavior?
3. Should cleanup run every command or only on `screenshot` (and optional explicit `cleanup`) in first iteration?
4. Should retention be a full 24h hard expiry or configurable via flag/env with hidden default override?

## 14. Validation Test Suite

Current suite: 40 tests.

Implemented with the feature work:

- `Tests/ScreenCommanderTests/KeyCodesTests.swift`
  - modifier aliases and normalization
  - expanded key catalog (`fn`, navigation, keypad, and function rows)
  - system key alias resolution and modifier restrictions
  - hold-target validation (`shift`, `fn`, unknown tokens)

- `Tests/ScreenCommanderTests/KeySequenceParserTests.swift`
  - hold/press/sleep token parsing
  - mixed keyboard + system sequence steps
  - invalid action and payload rejection

- `Tests/ScreenCommanderTests/CaptureRetentionManagerTests.swift`
  - managed cleanup extension allowlist
  - old-file pruning threshold
  - ignoring nested directories and non-managed file types
  - returns zero cleanup result when captures directory is absent

- `Tests/ScreenCommanderTests/StatePathsTests.swift`
  - default state directory
  - absolute and relative overrides

- `Tests/ScreenCommanderTests/ScreenCommanderEngineTests.swift`
  - default and explicit screenshot output path handling
  - default metadata sidecar location co-located with default image output
  - default last-metadata routing
  - `keys` sequence routing for system/keyboard steps
  - negative delay validation
  - cleanup defaults and negative guardrails

- `Tests/ScreenCommanderTests/SnapshotMetadataStoreTests.swift`
  - managed `lastMetadataURL` injection
