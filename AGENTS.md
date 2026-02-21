# AGENTS.md
For practical day-to-day operation of `screencommander`, use `SKILL.md` as the primary runbook (workflow, command patterns, validation, and troubleshooting).

## Quickstart: Correct Terminal Usage

Use this flow to go from launching the tool to interacting with on-screen content reliably.

1. Run from this repo (without installing to PATH):
   ```bash
   swift run screencommander --help
   ```
2. Verify permissions and displays:
   ```bash
   swift run screencommander doctor
   ```
3. Capture a Retina screenshot + metadata sidecar:
   ```bash
   swift run screencommander screenshot --out ~/Library/Caches/screencommander/captures/desk.png
   ```
   This writes `~/Library/Caches/screencommander/captures/desk.png` and `~/Library/Caches/screencommander/captures/desk.json` (or `~/Library/Caches/screencommander/last-screenshot.json` when using defaults).
4. Open the image in any viewer and pick a pixel coordinate `(x, y)` in screenshot space (origin: top-left).
5. Click content at that pixel using the matching metadata:
   ```bash
   swift run screencommander click <x> <y> --meta ~/Library/Caches/screencommander/last-screenshot.json
   ```
6. If UI selection needs two presses (e.g., list/sidebar rows), use double-click:
   ```bash
   swift run screencommander click <x> <y> --meta ~/Library/Caches/screencommander/last-screenshot.json --double
   ```
7. Send keyboard input to the focused app:
   ```bash
   swift run screencommander type "hello world"
   swift run screencommander key "enter"
   swift run screencommander key "cmd+tab"
   ```

Notes:
- `click` coordinates are screenshot pixels by default; do not mix metadata from a different screenshot.
- If a target window is not foregrounded, send two clicks: the first click sets cursor/focus position, and the second click performs the intended control interaction.
- `click`, `type`, `key`, and `keys` now capture both pre-action and post-action screenshots by default for immediate before/after feedback.
- Disable default before/after capture with `--no-postshot` when scripting speed/output noise matters.
- `sequence` runs bundled actions (`click`, `type`, `key`) in strict order from a JSON file and captures before/after screenshots per step by default.
- `keys` supports explicit step sequences, for example:
  - `screencommander keys press:cmd+tab press:cmd+tab`
- `cleanup` prunes old artifacts from `~/Library/Caches/screencommander/captures` only.
- If permission is missing, commands fail fast with explicit guidance and a System Settings deeplink.
- For installed usage, replace `swift run screencommander ...` with `screencommander ...`.
- Input/send fallback when `key "enter"` or `key "return"` does not send:
  1. Focus compose field with a click (or `--double` for non-foreground windows).
  2. Paste full text instead of per-character typing:
     ```bash
     printf '%s' 'your message' | pbcopy
     swift run screencommander key "cmd+v"
     ```
  3. Send via app activation + System Events Return:
     ```bash
     osascript -e 'tell application "Messages" to activate' -e 'tell application "System Events" to key code 36'
     ```
  This avoids focus races where keystrokes are captured by Terminal instead of Messages.
- Focus + double-click behavior observed in practice:
  1. First injected click often only moves/primes cursor/focus.
  2. Second injected click is the first human-equivalent click.
  3. For a human-equivalent double-click on an unfocused target, use 3 injected clicks total:
     ```bash
     swift run screencommander click <x> <y> --meta <json>
     swift run screencommander click <x> <y> --meta <json> --double
     ```
  4. In Finder app-grid workflows, if icon clicks only select and do not open, use launch fallback:
     ```bash
     open -a "Slack"
     ```
- Human click semantics in CLI:
  - `screencommander click ...` is the human-equivalent single click by default (internally compensated as needed).
  - Use `--raw` only when you want strict low-level event behavior without that compensation.

**Project**  
`screencommander` is a macOS Swift command-line tool that lets a user observe the desktop (Retina-accurate screenshot saved to disk) and act on it (mouse clicks and keyboard input) using terminal commands. The core value is a reliable “screenshot → pick coordinates → click/type” loop that works deterministically across Retina scaling and multiple displays.

**Mission**  
Enable driving a macOS desktop from the terminal with precise, repeatable input injection, using screenshots as the source of truth for coordinate selection.

**Goal**  
Ship a fully working, driveable CLI tool named `screencommander` that can, from Terminal, capture a Retina-quality screenshot to a file, persist coordinate mapping metadata, translate screenshot pixel coordinates into global event coordinates, and inject mouse/keyboard events into the system with clear permission handling.

**Operating model**  
The tool supports one-shot commands for scripting and an optional interactive mode later, but the fundamental workflow is identical: capture a screenshot and metadata, inspect the screenshot externally, then send click/type commands that reference the captured metadata to ensure exact mapping.

**Target platform**  
macOS 14+ is the baseline for the initial implementation, using ScreenCaptureKit’s screenshot APIs for modern, high-fidelity capture. Event injection uses Quartz Event Services (CoreGraphics / ApplicationServices).

**User experience contract**  
The tool must behave predictably when run from Terminal, not only from Xcode. It must clearly report when permissions are missing and provide an actionable path to enable them.

**Core capabilities**  

| Capability | User-facing behavior | Technical intent |
|---|---|---|
| Permission preflight | `screencommander doctor` reports Screen Recording and Accessibility status; commands fail fast with actionable messages if missing | Make permission state explicit and deterministic for users and scripts |
| Retina screenshot to file | `screencommander screenshot` writes an image (PNG by default) and a metadata JSON sidecar, then prints paths | Capture must preserve Retina pixel resolution and store mapping inputs |
| Coordinate mapping | `screencommander click x y` (pixels by default) lands exactly where the user selected in the screenshot | Convert screenshot pixel coordinates to global Quartz event coordinates using stored scale and bounds |
| Mouse clicks | Left/right click with optional double click | Use `CGEventCreateMouseEvent` and `CGEventPost` |
| Keyboard input | `screencommander type "..."` inserts text; `screencommander key "cmd+shift+4"` posts chords/special keys | Use `CGEventCreateKeyboardEvent` with Unicode string where possible plus keycode-based chords |

**CLI surface**  
The tool name is `screencommander`. Command names and flags are stable, designed for scripts, and must not depend on interactive prompts except where macOS permission dialogs are requested.

| Command | Example | Output expectations |
|---|---|---|
| `doctor` | `screencommander doctor` | Prints permission status and active displays with IDs and bounds; exits 0 even when permissions missing, but indicates status clearly |
| `screenshot` | `screencommander screenshot --display main --out /tmp/desk.png` | Writes `/tmp/desk.png` and `/tmp/desk.json` (or explicit `--meta`); prints absolute paths; exits nonzero on failure |
| `click` | `screencommander click 812 442 --meta /tmp/desk.json` | Performs click at the mapped point; exits nonzero if metadata missing or permissions not granted |
| `type` | `screencommander type "hello world"` | Injects keystrokes/text; exits nonzero if permissions not granted |
| `key` | `screencommander key "enter"` or `screencommander key "cmd+tab"` | Injects a special key or chord; exits nonzero on unknown chord strings |

The default coordinate space for `click` is screenshot pixels with origin at the screenshot’s top-left. Optional `--space points|pixels|normalized` may be added, but pixel space must be correct first.

**Data contract for mapping metadata**  
A screenshot is only “usable for driving” if the tool writes a metadata JSON that fully describes how to transform screenshot coordinates into global event coordinates. The metadata must be sufficient without consulting any runtime state other than the JSON itself.

Required fields are display identity, display bounds in global point space, screenshot image size in pixels, and the point-to-pixel scale used at capture time.

**Architecture constraints**  
The CLI layer stays thin and delegates all logic to core services. Input injection and capture are isolated behind small interfaces so the CLI can remain stable while internals evolve.

| Layer | Responsibility | Notes |
|---|---|---|
| CLI | Argument parsing, printing, exit codes | Uses ArgumentParser; no direct CoreGraphics calls |
| Core services | Permissions, display registry, coordinate mapping | Pure mapping code should be side-effect free |
| Capture | ScreenCaptureKit screenshot implementation | Returns `CGImage` plus mapping metadata inputs |
| Input | Mouse and keyboard event synthesis | Receives global points/keycodes only; no screenshot concerns |
| Persistence | Read/write metadata and “last capture” pointers | Default metadata path behavior must be explicit |

**Definition of done**  
This project is done when a developer can build the binary and a user can run the following from Terminal on macOS 14+ with predictable results.

| Requirement | Acceptance criteria |
|---|---|
| Binary identity and invocation | `screencommander --help` works; subcommands are discoverable; exit codes are consistent |
| Permission handling is explicit | `screencommander doctor` shows Screen Recording and Accessibility status; `screencommander screenshot` requests Screen Recording when missing (or exits with a clear instruction if it cannot); `click/type/key` request Accessibility when missing (or exit with a clear instruction) |
| Retina screenshot fidelity | `screencommander screenshot --display main --out <path>` creates a viewable image whose pixel dimensions match the display’s effective pixel resolution for the captured region |
| Metadata correctness | The sidecar JSON contains all required mapping fields and references the image path; reusing the JSON later yields the same coordinate mapping |
| Click accuracy from screenshot pixels | After taking a screenshot and selecting a pixel coordinate from the saved image, `screencommander click x y --meta <json>` clicks the visually corresponding location on the desktop reliably, including on Retina displays |
| Keyboard input works in typical apps | `screencommander type "abc"` inserts “abc” into a focused text field in standard applications; `screencommander key "enter"` triggers Enter; common modifier chords like `cmd+v` are supported |
| Multi-display selection | `screencommander screenshot --display <id>` targets the chosen display; the resulting metadata maps clicks correctly on that display |
| Scriptable output option | `--json` mode prints machine-readable results for `doctor` and `screenshot`, including paths and display identifiers |
| Deterministic failure modes | Missing permissions, invalid coordinates, missing metadata, or unsupported display IDs produce a nonzero exit code and a specific error message that identifies the cause and corrective action |

**Non-negotiable behaviors**  
The screenshot command must always produce metadata that makes click mapping possible. Coordinate mapping must not silently guess or “auto-correct” display scale; it must use captured metadata. Commands must not succeed silently when they did nothing due to permissions; they must surface that state.

**Initial implementation milestone**  
The first milestone is a complete “loop”: `doctor` confirms permissions and shows displays, `screenshot` writes PNG+JSON for one selected display, `click` maps screenshot pixels to global coordinates and posts a click, and `type` injects text. All four must work from Terminal with the same built artifact.

## Project Mission
Build `screencommander`, a macOS command-line automation utility that enables a full terminal-driven “observe → decide → act” loop. The tool must capture a Retina-accurate desktop image, persist mapping metadata, and translate user-provided screenshot coordinates and key instructions into reliable global mouse and keyboard events. The CLI must remain thin and intentionally focused on command parsing/UX, while all system control remains in reusable core services.

## Execution Protocol
- The implementation goal is to execute `INIT.md` end-to-end phase by phase without skipping unfinished work.
- `INIT.md` is the source of truth for active TODOs, phase status, and implementation notes.
- As progress is made, update TODO checkboxes and add dated notes in `INIT.md`.
- Do not declare the project complete until `INIT.md` Definition of Done criteria are all satisfied or explicitly blocked with notes.

## Scope and Primary Outcomes
The implemented system must support four capabilities as first-class features:
1. Desktop screenshot capture (Retina/point-aware) to a local image file.
2. Deterministic coordinate mapping from screenshot space to Quartz global event coordinates.
3. Mouse click execution from mapped coordinates.
4. Keyboard input via text and key chords.

All user-facing permission requirements (Screen Recording and Accessibility) must be handled up front with clear error guidance and actionable OS links.

## Core Architecture
The codebase must be organized into a small set of bounded domains:
- **CLI layer** (`Sources/screencommander/CLI/*`): only argument parsing, output formatting, and command dispatch.
- **Core services** (`Sources/screencommander/Core/*`): permission checks, display metadata, and coordinate conversion.
- **Capture services** (`Sources/screencommander/Capture/*`): screen image acquisition and image persistence.
- **Input services** (`Sources/screencommander/Input/*`): mouse and keyboard event synthesis.
- **Persistence** (`Sources/screencommander/Persistence/*`): screenshot metadata writing and retrieval.

`main` and command handlers must call a shared engine object that wires capabilities and prevents duplicated logic.

## Non-negotiable Technical Requirements
- Target macOS 14+ for primary ScreenCaptureKit use.
- Use `SCScreenshotManager` to capture screenshots where available.
- Use Quartz event APIs (`CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventKeyboardSetUnicodeString`) for interactions.
- Use `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` and `AXIsProcessTrustedWithOptions` for permission checks.
- Serialize metadata in JSON with primitives only (no CoreGraphics structs).
- Include captured display ID, bounds in points, image dimensions in pixels, and point→pixel scale in metadata.

## Permission & UX Contract
Every command requiring a capability must validate prerequisites and fail fast with explicit status text:
- `screenshot` must verify screen recording access.
- `click`, `type`, and `key` must verify accessibility trust.
- If denied, print a recovery path and the relevant System Settings deeplink.

## Coordinate Contract
Default accepted coordinate space for `click` is screenshot pixel coordinates with image-origin top-left. Mapping must convert pixel coordinates to global Quartz coordinates using metadata scale and display bounds. Coordinate conversion must be pure, deterministic, and testable from metadata + input.

## Definition of Done
The project is done only when all conditions are met:
- `screencommander screenshot` writes image + `.json` metadata and can optionally emit JSON to stdout.
- `screencommander click x y` correctly targets the intended display pixel from screenshot space and produces one-click/optional double-click behavior.
- `screencommander type "..."` posts Unicode text safely and `screencommander key "cmd+shift+4"` posts a mapped chord.
- Permission preflight behavior works consistently on first-run and documents exact next steps on denial.
- A single last-screenshot metadata file exists by default, with `--meta` override support.
- Commands are deterministic and idempotent where possible, with clean error codes and human-readable usage.
- The CLI remains thin: no low-level mapping or event details outside Core/Input/Persistence modules.
- Documentation includes command examples for screenshot, click, type, and key workflows and lists required macOS permissions.
- Any extension plan for compatibility fallback or optional agent `.app` model is documented as a future consideration, not partially implemented in core.

## Verification Boundaries
At completion, the code must satisfy compile-time conformance to the modules above, include minimal but explicit error messaging for permission/API failures, and preserve compatibility with future refactors into GUI/XPC while keeping the same service interfaces.
