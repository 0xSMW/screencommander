# ScreenCommander INIT Spec

## 1. Goal
Build a macOS command-line tool named `screencommander` that supports a full terminal automation loop:
1. Observe: capture a Retina-accurate screenshot to disk.
2. Decide: resolve screenshot coordinates deterministically.
3. Act: inject global mouse and keyboard events.

The implementation must keep CLI parsing thin and centralize OS integration logic in reusable services.

## 2. Target Platform and Constraints
- OS target: macOS 14.0+.
- Primary capture API: `SCScreenshotManager` (ScreenCaptureKit).
- Input API: Quartz Event Services (`CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventKeyboardSetUnicodeString`).
- Permissions:
  - Screen capture: `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`.
  - Accessibility: `AXIsProcessTrustedWithOptions`.
- Metadata format: JSON primitives only (no raw CoreGraphics structs).

## 3. First-Class Capabilities
1. `screencommander screenshot`
   - Captures a display at Retina fidelity.
   - Writes image file (`png` default, optional `jpeg`).
   - Writes sidecar metadata JSON (or path from `--meta`).
2. `screencommander click <x> <y>`
   - Accepts screenshot pixel coordinates by default (`origin: top-left`).
   - Maps to global Quartz coordinates using metadata.
   - Posts single click or optional double click.
3. `screencommander type "<text>"`
   - Posts Unicode text input events.
4. `screencommander key "<chord>"`
   - Posts key chords (`cmd+shift+4`, `enter`, arrows, etc).

## 4. CLI Contract
Use `swift-argument-parser` and expose:
- Help UX requirement:
  - `screencommander --help` must provide verbose top-level guidance with workflow context and practical examples.
  - Every subcommand help (`screenshot`, `click`, `type`, `key`, `doctor`) must include detailed flag behavior, coordinate/input expectations, and examples so a novice can quickly become an advanced user.

1. `screencommander screenshot`
- Flags:
  - `--display <id|main>` default `main`
  - `--out <path>` default `./Screenshot-<timestamp>.png`
  - `--format <png|jpeg>` default `png`
  - `--meta <path>` default `<image>.json` and also update `last-screenshot.json`
  - `--cursor` include cursor in capture
  - `--json` print machine-readable result
- Behavior:
  - Requires screen recording permission.
  - Writes image + metadata.
  - Exit non-zero with actionable permission guidance on failure.

2. `screencommander click <x> <y>`
- Flags:
  - `--space <pixels|points|normalized>` default `pixels`
  - `--meta <path>` default `last-screenshot.json`
  - `--button <left|right>` default `left`
  - `--double` optional double click
  - `--json` print resolved point/result
- Behavior:
  - Requires accessibility permission.
  - Loads metadata, maps coordinate, posts mouse events.

3. `screencommander type "<text>"`
- Flags:
  - `--delay-ms <n>` optional per-event delay
  - `--json` optional machine output
- Behavior:
  - Requires accessibility permission.
  - Posts Unicode keyboard events.

4. `screencommander key "<chord>"`
- Examples:
  - `enter`
  - `cmd+shift+4`
  - `option+tab`
- Flags:
  - `--json`
- Behavior:
  - Requires accessibility permission.
  - Parses chord and posts key down/up sequence.

## 5. Repository Layout (Single Target, Modular Folders)
Create these folders under `Sources/ScreenCommander` if/when converted to SwiftPM layout, or mirror inside the Xcode target group if staying pure Xcode project:

- `CLI/`
  - `RootCommand.swift`
  - `ScreenshotCommand.swift`
  - `ClickCommand.swift`
  - `TypeCommand.swift`
  - `KeyCommand.swift`
- `Core/`
  - `ScreenCommanderEngine.swift`
  - `Permissions.swift`
  - `Displays.swift`
  - `CoordinateMapping.swift`
  - `Errors.swift`
- `Capture/`
  - `ScreenCapturer.swift`
  - `ScreenCaptureKitCapturer.swift`
  - `ImageWriter.swift`
- `Input/`
  - `MouseController.swift`
  - `KeyboardController.swift`
  - `KeyCodes.swift`
- `Persistence/`
  - `SnapshotMetadataStore.swift`
  - `Models.swift`

`main.swift` should only bootstrap `RootCommand.main()`.

## 6. Core Data Contracts
```swift
struct ScreenshotMetadata: Codable {
    var capturedAtISO8601: String
    var displayID: UInt32
    var displayBoundsPoints: RectD
    var imageSizePixels: SizeD
    var pointPixelScale: Double
    var imagePath: String
}

struct RectD: Codable { var x: Double; var y: Double; var w: Double; var h: Double }
struct SizeD: Codable { var w: Double; var h: Double }
```

Rules:
- `displayBoundsPoints` is Quartz global point-space for the captured display.
- `imageSizePixels` is actual encoded file size.
- `pointPixelScale` must satisfy approximately:
  - `imageSizePixels.w ~= displayBoundsPoints.w * pointPixelScale`
  - `imageSizePixels.h ~= displayBoundsPoints.h * pointPixelScale`

## 7. Coordinate Mapping Contract
Default input is screenshot pixels with top-left origin.

For input `(px, py)` in pixel space:
- `dxPoints = px / pointPixelScale`
- `dyPoints = py / pointPixelScale`
- `xGlobal = displayBoundsPoints.x + dxPoints`
- `yGlobal = displayBoundsPoints.y + dyPoints`

Validation:
- Reject out-of-bounds coordinates unless `--allow-outside` is introduced later.
- Return explicit error if metadata missing or malformed.

`CoordinateMapper` must be pure (no side effects), deterministic, and unit-testable.

## 8. Permissions and UX
Every command validates prerequisites before executing side effects.

1. `screenshot`
- Check `CGPreflightScreenCaptureAccess()`.
- If missing and interactive mode enabled, call `CGRequestScreenCaptureAccess()`.
- On denial, print:
  - why it failed,
  - how to fix,
  - deeplink: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.

2. `click`, `type`, `key`
- Check `AXIsProcessTrustedWithOptions(...)`.
- If not trusted, request prompt via `kAXTrustedCheckOptionPrompt`.
- On denial, print deeplink:
  - `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

Permission failures must produce stable non-zero exit codes and human-readable guidance.

## 9. Capture Implementation Notes
- Enumerate displays with `SCShareableContent`.
- Resolve chosen display (`main` or explicit ID).
- Create `SCContentFilter(display:excludingWindows:)`.
- Use `filter.contentRect` and `filter.pointPixelScale`.
- Configure `SCStreamConfiguration` width/height from those values.
- Capture via `SCScreenshotManager.captureImage(...)`.
- Encode image via `CGImageDestination` (`public.png` / `public.jpeg`).
- Persist metadata adjacent to image and write/update `last-screenshot.json`.

## 10. Input Implementation Notes
Mouse:
- Build `CGEvent` for move + down + up at mapped global point.
- Set click state/count for double-click path.
- Support left/right button.

Keyboard:
- `type(text:)` uses Unicode string injection events.
- `press(chord:)` uses virtual keycodes + modifier flags.
- Keycode map is centralized in `Input/KeyCodes.swift`.
- Parse aliases (`cmd`, `command`, `opt`, `option`, `ctrl`, `control`).

## 11. Error Model and Exit Codes
Define `ScreenCommanderError: Error, CustomStringConvertible` with stable codes:
- `10`: permission denied (screen recording)
- `11`: permission denied (accessibility)
- `20`: capture failed
- `21`: image write failed
- `30`: metadata read/write failed
- `40`: invalid coordinate
- `41`: mapping failed
- `50`: input synthesis failed
- `60`: invalid CLI arguments/chord parse

CLI prints concise human-readable errors to stderr and exits with the mapped code.

## 12. Detailed Phases and TODO Tracker

Tracker rules:
- Work phases in order unless a blocker requires reordering.
- Keep phase `Status` updated as `TODO`, `IN_PROGRESS`, `BLOCKED`, or `DONE`.
- Record dated implementation notes under the phase where work occurred.
- Do not mark the project complete until all Definition of Done items in this file are satisfied.

### Phase 1 - Foundation
Status: `DONE`

TODO:
- [x] Add `swift-argument-parser` to the project.
- [x] Set macOS deployment target to `14.0`.
- [x] Link required frameworks: `ScreenCaptureKit`, `ApplicationServices`, `CoreGraphics`, `ImageIO`, `UniformTypeIdentifiers`.
- [x] Replace Hello World `main.swift` with CLI bootstrap entry.
- [x] Create folder/module skeleton (`CLI`, `Core`, `Capture`, `Input`, `Persistence`).
- [x] Add `ScreenCommanderEngine` as shared command orchestrator.
- [x] Define shared error model and stable exit code mapping.
- [x] Define metadata models (`ScreenshotMetadata`, `RectD`, `SizeD`).

Exit criteria:
- [x] Project builds with skeleton architecture in place.
- [x] Commands can dispatch through a single engine entrypoint.

Notes:
- [x] 2026-02-20: Converted project to SwiftPM (`Package.swift`) with macOS 14 target, added `swift-argument-parser`, linked required frameworks, replaced bootstrap with `RootCommand.main()`, and created CLI/Core/Capture/Input/Persistence structure with shared engine.

### Phase 2 - Permissions and Display Discovery
Status: `DONE`

TODO:
- [x] Implement screen recording preflight + optional prompt path.
- [x] Implement accessibility preflight + optional prompt path.
- [x] Add clear denial recovery messages with deeplinks.
- [x] Implement display discovery service with display ID and bounds in points.
- [x] Expose main display resolution strategy for `--display main`.
- [x] Add command-level capability gates (`screenshot` vs `click/type/key`).

Exit criteria:
- [x] Permission-denied flows return stable non-zero exit codes and clear remediation text.
- [x] Display lookup returns deterministic display metadata for capture and mapping.

Notes:
- [x] 2026-02-20: Implemented permission preflight/request flows (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `AXIsProcessTrustedWithOptions`) with deeplink remediation messaging and deterministic display resolution (`main` or explicit display ID) via ScreenCaptureKit shareable content.

### Phase 3 - Screenshot Capture and Metadata Persistence
Status: `DONE`

TODO:
- [x] Implement `ScreenCapturer` protocol and `ScreenCaptureKit` implementation.
- [x] Resolve target display by explicit ID or `main`.
- [x] Configure capture dimensions from `contentRect * pointPixelScale`.
- [x] Capture image via `SCScreenshotManager`.
- [x] Implement image writer for PNG and JPEG via ImageIO.
- [x] Implement metadata store save/load APIs.
- [x] Write sidecar metadata JSON and update `last-screenshot.json`.
- [x] Implement `screencommander screenshot` command flags and output formats (`human`, `--json`).

Exit criteria:
- [x] Screenshot command writes image + metadata and reports output paths.
- [x] Metadata contains display bounds, image pixel size, and `pointPixelScale`.

Notes:
- [x] 2026-02-20: Implemented `ScreenCaptureKitCapturer`, ImageIO-backed PNG/JPEG writer, metadata persistence with sidecar + `last-screenshot.json`, and `screenshot` command flags/output (`human` + `--json`).

### Phase 4 - Coordinate Mapping and Mouse Input
Status: `DONE`

TODO:
- [x] Implement pure coordinate mapper for `pixels`, `points`, and `normalized`.
- [x] Validate coordinates and produce explicit mapping errors.
- [x] Implement `MouseController` event posting for move/down/up.
- [x] Implement right-click and double-click behavior.
- [x] Implement `screencommander click <x> <y>` command with `--meta`, `--space`, `--button`, `--double`.
- [x] Ensure click command resolves metadata from default `last-screenshot.json` with override support.

Exit criteria:
- [x] Click command maps screenshot coordinates to global coordinates deterministically.
- [x] Mapped click target is reproducible from metadata + input alone.

Notes:
- [x] 2026-02-20: Implemented pure coordinate mapping for `pixels|points|normalized`, bounds validation errors, mouse move/down/up synthesis with left/right + double click, and `click` command metadata fallback to `last-screenshot.json`.

### Phase 5 - Keyboard Input
Status: `DONE`

TODO:
- [x] Implement keycode/modifier mapping table in one file (`KeyCodes.swift`).
- [x] Implement chord parser for modifier aliases (`cmd`, `option`, `ctrl`, etc.).
- [x] Implement `KeyboardController.type(text:)` using Unicode injection events.
- [x] Implement `KeyboardController.press(chord:)` for key down/up sequencing.
- [x] Add special-key support (`enter`, `tab`, `escape`, arrows, delete, space).
- [x] Implement `screencommander type` command flags and behavior.
- [x] Implement `screencommander key` command flags and behavior.

Exit criteria:
- [x] Text injection and chord injection are both functional under accessibility trust.
- [x] Invalid chord input returns stable parse error code and clear guidance.

Notes:
- [x] 2026-02-20: Implemented centralized keycode/modifier mapping and chord parser (`KeyCodes.swift`), Unicode text injection and chord press sequencing in `KeyboardController`, plus `type` and `key` command behaviors with stable parse errors.

### Phase 6 - Hardening, UX, and Documentation
Status: `DONE`

TODO:
- [x] Standardize command JSON output schema for scriptability.
- [x] Ensure all command failures map cleanly to defined exit codes.
- [x] Normalize human-readable error messages for permission/API failures.
- [x] Add README usage docs for screenshot/click/type/key workflows.
- [x] Document required macOS permissions and first-run behavior.
- [x] Confirm CLI layer remains thin (no low-level mapping/event logic in command files).
- [x] Add future-considerations note for optional `.app`/XPC model (non-implemented).

Exit criteria:
- [x] Documentation and UX match implementation behavior.
- [x] Architecture boundaries remain aligned with this spec.

Notes:
- [x] 2026-02-20: Standardized command success JSON envelope (`status`, `command`, `result`), normalized error-to-exit-code mapping, kept CLI files thin by delegating logic to engine/services, and added README usage/permission/future-considerations docs.

### Project Completion Gate
Status: `DONE`

TODO:
- [x] Reconcile implemented behavior against all items in Section 13 Definition of Done.
- [x] Mark each phase status as `DONE` or capture remaining blockers in notes.
- [x] Summarize open follow-ups under Section 14 Future Considerations only.

Notes:
- [x] 2026-02-20: Verified build/tests and command surfaces (`help`, exit codes, permission messaging), reconciled implementation to Section 13, and left only Section 14 items as future non-implemented considerations.

## 13. Definition of Done
All of the following must be true:
1. `screencommander screenshot` writes image + metadata JSON and can emit JSON output.
2. `screencommander click x y` maps screenshot coords correctly and clicks expected target.
3. `screencommander type "..."` injects Unicode text.
4. `screencommander key "cmd+shift+4"` injects chord.
5. Permission preflight is explicit and actionable for both capability classes.
6. `last-screenshot.json` is maintained with optional `--meta` override.
7. CLI stays thin; mapping/event internals stay out of command handlers.
8. Docs include command examples and required permission setup.
9. Help output is verbose at both top-level and subcommand levels, with clear examples and operational detail that allow a novice to become an advanced user quickly.

## 14. Future Considerations (Not in Initial Scope)
- CLI + background `.app`/XPC split for more stable TCC behavior when distributing.
- Pre-macOS 14 fallback capture backend.
- Optional interactive REPL that reuses same `ScreenCommanderEngine`.
