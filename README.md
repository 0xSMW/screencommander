# screencommander

<img width="900" height="525" alt="image" src="https://github.com/user-attachments/assets/ea6eccab-5db4-4df1-b8e3-741914167e2d" />

`screencommander` is a macOS 14+ CLI and MCP server that gives agents an observe → decide → act loop over the desktop, accessibility-first: read the screen as structured data when possible, capture pixels when needed, and act without taking the user's mouse.

1. **Observe** — Retina-aware screenshots (full display or a single window), the accessibility tree as structured elements or plain text (`elements`, ~30–80 ms with no capture), a real-time stream of UI-change events (`observe`), and a pre/post frame diff on every action that answers "did that do anything?" without re-reading images.
2. **Decide** — deterministic coordinate mapping from capture metadata (pixels, points, or normalized → global points, window-relative included), element ids and bounds that are directly clickable, and `--until` predicates for blocking until the UI reaches a state.
3. **Act** — click, scroll, drag, hover, type, and key chords, delivered through a tier ladder: coordinate-free accessibility actions → process-targeted events posted straight to an app (cursor untouched, works on background windows) → global event synthesis. `--no-cursor` guarantees the pointer never moves.

Vision models work from screenshots and pixel coordinates. Non-vision models (for example `codex-5.3-codex-spark`) work from the element tree and text alone — same commands, same JSON envelopes. `serve --mcp` exposes the entire surface as MCP tools with screenshots returned in-band.

## Requirements

- macOS 14.0+
- Xcode Command Line Tools (for `swift`)

## Build

```bash
swift build
```

## Fast Capability Guide

For a concise, operations-first guide to `screencommander` capabilities and reliable command patterns, see:

- `SKILL.md`

This is the same skill/runbook AGENTS use to quickly understand and operate the CLI.

## Install

Use the reusable installer script:

```bash
scripts/install.sh --prefix /usr/local
```

If you prefer a user-local install without `sudo`:

```bash
scripts/install.sh --prefix "$HOME/.local"
```

The binary is installed to `<prefix>/bin/screencommander`.
For user-local installs, ensure `~/.local/bin` is on your `PATH`.

## Permissions

`screencommander` requires macOS privacy permissions:

1. Screen Recording permission for `screenshot`
- System Settings path: Privacy & Security > Screen Recording
- Deeplink: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`

2. Accessibility permission for `click`, `scroll`, `drag`, `move`, `type`, `key`, `elements`, and `observe`
- System Settings path: Privacy & Security > Accessibility
- Deeplink: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

On denial, commands fail fast with explicit remediation text and stable exit codes.

## Commands

### Doctor

```bash
screencommander doctor
screencommander doctor --json
```

Behavior:

- Reports permission status with traffic lights (`🟢` granted, `🔴` denied).
- Reports active displays with IDs and bounds in points.
- Exits `0` even if permissions are missing; use output for remediation.

### Screenshot

```bash
screencommander screenshot \
  --display main \
  --out ~/Library/Caches/screencommander/captures/desk.png \
  --format png \
  --meta ~/Library/Caches/screencommander/captures/desk.json \
  --cursor
```

JSON output variant:

```bash
screencommander screenshot --json
```

Behavior:

- Captures with ScreenCaptureKit `SCScreenshotManager`.
- Writes image and JSON metadata.
- Default image path: `~/Library/Caches/screencommander/captures/<timestamp>.png`
- Default metadata path: `<image>.json` (for example `~/Library/Caches/screencommander/captures/<timestamp>.json`)
- Also updates managed `~/Library/Caches/screencommander/last-screenshot.json` by default.
- Does not prune older captures; use `cleanup` explicitly when you want retention.

### Click

```bash
screencommander click 640 320 --space pixels
```

Using explicit metadata and double-right-click:

```bash
screencommander click 0.25 0.25 \
  --space normalized \
  --meta ./captures/desk.json \
  --button right \
  --double
```

Modifier and middle/triple-click examples:

```bash
screencommander click 640 320 --button middle
screencommander click 640 320 --modifiers cmd,shift
screencommander click 640 320 --triple
```

Pointer-free element clicks (no coordinates, cursor untouched):

```bash
screencommander click --element "General" --app "System Settings" --no-cursor
screencommander click --element-id 0.3.2 --app Safari
screencommander click --element "Save" --role button --via ax
screencommander click 640 320 --verify-target
```

Behavior:

- Defaults to metadata path `~/Library/Caches/screencommander/last-screenshot.json`.
- Maps screenshot coordinates into global Quartz coordinates deterministically.
- Supports `--button left|right|middle`, `--double`, `--triple`, and `--modifiers cmd,shift,option,ctrl`.
- `--element "<title/label substring>"` or `--element-id <id>` clicks an accessibility element instead of coordinates. Resolution happens fresh at click time (ids from `elements` are positional). No match exits `70` (`element_not_found`); ambiguous substring matches exit `82` (`element_ambiguous`). Disambiguate with `--element-id`, `--role`, and `--app`.
- Element clicks use a tiered actuator, tried in order `ax` (AXPress/AXShowMenu — coordinate-free, background-safe) → `pid` (CGEvents posted to one app; cursor stays put) → `global` (classic path; moves the cursor). Downgrades are recorded in the result (`deliveryMethod`), not errors.
- Disabled elements fail with exit `72` before any fallback tier runs.
- `--via ax|pid|global` forces one tier with no fallback (`--strict` implied). `--no-cursor` removes the `global` tier so the pointer never moves. `--strict` turns any downgrade into exit `72` (`element_not_actionable`).
- Coordinate clicks keep the historical `global` delivery; `--via pid` with `--app <name|pid>` posts a coordinate click to one app instead.
- `--verify-target` (coordinate clicks) hit-tests the mapped point via accessibility first and includes the element found there in the result.
- Captures pre-action and post-action screenshots by default and prints both paths.
- Compares pre-action and post-action screenshots and reports a changed region when pixels differ.
- Disable before/after capture with `--no-postshot`.
- Disable only frame comparison with `--no-diff`.

### Scroll

```bash
screencommander scroll 640 800 --dy -5
screencommander scroll 640 800 --dy 300 --unit pixels
screencommander scroll 640 800 --dx 2 --dy 0
```

Element-targeted and pid-delivered scrolling:

```bash
screencommander scroll --element "Content" --app Safari --dy -5
screencommander scroll 640 800 --dy -5 --via pid --app Safari
```

Behavior:

- Maps the target point through screenshot metadata, moves the cursor there, then posts a scroll event.
- Uses line units by default; pass `--unit pixels` for pixel scrolling.
- Requires at least one nonzero delta across `--dx` and `--dy`.
- `--element`/`--element-id` scrolls at an element's center. There is no AX scroll action, so element scrolls try `pid` then `global`; `--no-cursor` restricts to `pid`; `--via pid|global` forces a tier. The result records `deliveryMethod`.
- Captures pre-action and post-action screenshots by default (`--no-postshot` to disable).

### Drag

```bash
screencommander drag 300 400 900 400
screencommander drag 300 400 900 400 --button right --steps 20 --duration-ms 600
```

Behavior:

- Maps both endpoints through the same metadata and coordinate space.
- Posts mouse-down, interpolated drag events, and mouse-up.
- Defaults to `--steps 12` and `--duration-ms 300`.
- Captures pre-action and post-action screenshots by default (`--no-postshot` to disable).

### Move

```bash
screencommander move 640 320
screencommander move 640 320 --dwell-ms 250
```

Behavior:

- Maps screenshot coordinates to global Quartz coordinates and posts one mouse-move event.
- Sleeps after the move when `--dwell-ms` is provided.
- Captures pre-action and post-action screenshots by default (`--no-postshot` to disable).

### Type

```bash
screencommander type "hello world"
```

With per-character delay and JSON output:

```bash
screencommander type "delayed text" --mode unicode --delay-ms 50 --json
```

Typing into an element without keyboard focus games:

```bash
screencommander type "user@example.com" --element "Email" --app Safari
screencommander type "hello" --element-id 0.4.1 --via ax
```

Behavior:

- Defaults to paste mode (`cmd+v`) for reliable full-text input.
- `--element`/`--element-id` targets an accessibility element: tier `ax` sets `AXValue` directly (works on background apps), falling back to focusing the element and using the keyboard path (`global`). `type` has no `pid` tier. `--via ax|global` forces a tier; `--strict` turns downgrades into exit `72`.
- Captures pre-action and post-action screenshots by default (`--no-postshot` to disable).
- Compares pre-action and post-action screenshots by default (`--no-diff` to disable).

### Key

```bash
screencommander key "enter"
screencommander key "cmd+shift+4"
screencommander key "option+tab" --json
screencommander key "spotlight"
screencommander key "missioncontrol"
screencommander key "launchpad"
```

Supported modifier aliases include `cmd|command`, `opt|option|alt`, and `ctrl|control`.
System/media keys are also supported (for example `volumeup`, `volumedown`, `brightnessup`, `mute`, `launchpad`, `play`, `next`, `prev`).
`spotlight` and `raycast` map to `cmd+space`; `missioncontrol` maps to `f3`.

Behavior:

- Captures pre-action and post-action screenshots by default (`--no-postshot` to disable).
- Compares pre-action and post-action screenshots by default (`--no-diff` to disable).

### Keys

```bash
screencommander keys "press:cmd+tab" "press:cmd+tab"
screencommander keys "press:next" "sleep:100" "press:prev"
```

`keys` executes `down`/`up`/`press`/`sleep` steps in strict order.
For repeated modifier-based shortcuts, include modifiers explicitly in each `press` step (for example `press:cmd+tab`). Standalone keys such as `press:next` and `press:prev` do not require modifiers.
It captures and compares pre-action and post-action screenshots by default; use `--no-postshot` or `--no-diff` to disable those separately.

### Elements

Read an app's accessibility (AX) element tree — ground-truth UI structure and text without pixels:

```bash
screencommander elements                       # frontmost app, focused window
screencommander elements --app Safari --text   # text-only view of the UI
screencommander elements --app 8412 --json     # by pid, machine-readable
screencommander elements --app "System Settings" --roles AXButton,AXTextField --visible-only
```

Behavior:

- Defaults to the frontmost application; target explicitly with `--app <name|pid>`. Ambiguous app names report candidate PIDs so callers can retry with a PID.
- Traverses the focused window by default; use `--all-windows` or `--window-id <id>` to widen or narrow.
- Each element carries a positional id (dot-joined child-index path such as `0.3.2`), role, title/value/description, enabled/focused state, supported AX actions, and bounds in global points.
- When `~/Library/Caches/screencommander/last-screenshot.json` exists, elements inside that screenshot also get `boundsPixels` in its pixel space, so `elements` output can drive `click <x> <y>` directly.
- `--text` prints an indented `role "title": value` view (also in `result.text` with `--json`) — a token-cheap way to read a screen without vision.
- `--max-depth` (default 40, max 200), `--max-elements` (default 2000, max 10000, result marked `truncated` when hit), `--max-value-length` (200), `--roles`, and `--visible-only` bound the traversal.
- Electron/Chromium apps are primed automatically (`AXManualAccessibility`, falling back to `AXEnhancedUserInterface`, restored afterwards); the result reports `axPrimed`.
- Apps that expose no usable AX tree fail with exit code `71` (`ax_tree_unavailable`).

### Observe

Stream real-time UI-change events for an app as NDJSON (one JSON object per line) — a push-based feed so agents can block on outcomes instead of screenshot polling:

```bash
screencommander observe --app TextEdit --events value          # value changes as you type
screencommander observe --app Finder --until 'role=AXWindow title~=Downloads' --timeout-ms 10000
screencommander observe --app Safari --events focus,window     # focus and window changes
```

Behavior:

- Streams **NDJSON**, one event per line: `{ ts, event, app: { pid, name }, element? }`. This command always emits one-line JSON (it ignores pretty/compact).
- `--events` selects categories (default all): `value` (value changed), `focus` (focused element changed), `window` (created/moved/resized/title changed), `destroy` (element destroyed), `app` (NSWorkspace launch/activate/terminate for the target app).
- Runs until Ctrl-C (SIGINT, exit `0`), `--timeout-ms` elapses, or `--until` matches.
- `--until '<predicate>'` stops when an element matches: whitespace-joined `key<op>value` conditions where `key` is `role`/`title`/`value`/`id` and `<op>` is `=` (exact) or `~=` (case-insensitive contains), e.g. `role=AXButton title~=Save`. An initial tree scan makes already-true conditions return immediately. On match, a final `{ "matched": true, "element": ... }` line is printed (exit `0`).
- With `--until` and `--timeout-ms`, an unmet predicate within the timeout exits `73` (`observe_timeout`); a plain `--timeout-ms` without `--until` exits `0`.
- Requires Accessibility permission.

### Cleanup

```bash
screencommander cleanup --older-than-hours 24
```

Explicitly prunes managed capture artifacts (`png`, `jpg`, `jpeg`, `json`) in `~/Library/Caches/screencommander/captures` older than the configured age. Screenshot and action commands never run cleanup implicitly.

### Sequence

Run an ordered bundle of actions from JSON:

```bash
screencommander sequence --file ./sequence.json
```

Example `sequence.json`:

```json
{
  "steps": [
    { "click": { "x": 935, "y": 1074, "meta": "./last-screenshot.json" } },
    { "scroll": { "x": 935, "y": 800, "dy": -4 } },
    { "move": { "x": 935, "y": 700, "dwellMS": 100 } },
    { "type": { "text": "hello from sequence", "mode": "paste" } },
    { "sleep": { "ms": 100 } },
    { "key": { "chord": "enter" } }
  ]
}
```

Behavior:

- Executes steps in order.
- Step keys are exactly one of `click`, `scroll`, `drag`, `move`, `type`, `key`, or `sleep`.
- `click`, `scroll`, and `type` steps accept the element-targeting fields `element`, `elementId`, `role`, `app`, `via`, `noCursor` (`click`/`scroll`), and `strict`, mirroring the CLI options (for example `{ "click": { "element": "Save", "app": "TextEdit", "via": "ax" } }`).
- Captures pre-action and post-action screenshots around each step by default.
- Disable per-step before/after capture with `--no-postshot`.
- Compares each step's pre-action and post-action screenshots by default. Use command-level `--no-diff` or a step-level `noDiff: true` field to disable comparison.

### Windows

List visible windows, optionally filtered by app:

```bash
screencommander windows
screencommander windows --app Safari
screencommander windows --json
```

Behavior:

- Requires Screen Recording permission.
- Without `--app`, lists all visible windows across all apps.
- `--app` accepts an app name (exact or prefix) or a PID.
- Each row shows: `[windowID] AppName: "title" (WxH at X,Y, layer=N)`.
- Exits non-zero with code `81` if the app is not found.

### Screenshot (window capture)

Capture a single window instead of the full display:

```bash
screencommander screenshot --window 12345
screencommander screenshot --window Safari
```

Behavior:

- `--window` accepts a numeric window ID or an app-name prefix (captures the frontmost window of that app).
- The sidecar metadata gains optional `windowID` and `windowBoundsPoints` fields.
- `click` coordinates from a window screenshot map correctly using the window bounds as the origin.
- Without `--window`, screenshot behavior is unchanged (full display).

### Focus

Bring an app to the foreground:

```bash
screencommander focus --app Safari
screencommander focus --app 1234
screencommander focus --app Safari --json
```

Behavior:

- `--app` accepts an app name (exact or prefix) or a PID.
- Prints `Focused <AppName> (was: <PriorAppName>)`.
- Exits non-zero with code `81` if the app is not found.

### Serve (MCP server)

Run screencommander as a persistent MCP server over stdio:

```bash
screencommander serve --mcp
```

Register it with Claude Code:

```bash
claude mcp add screencommander -- screencommander serve --mcp
```

Behavior:

- Speaks the Model Context Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout
  (`initialize`, `tools/list`, `tools/call`); diagnostics go to stderr.
- Exposes every command as a tool: `screenshot`, `click`, `type`, `key`, `keys`,
  `scroll`, `drag`, `move`, `elements`, `windows`, `focus`, `observe_wait`, `doctor`,
  `cleanup`.
- One warm engine instance serves all calls — no per-action process startup — and
  tool results are the same JSON envelopes the CLI prints (as `structuredContent`
  plus a text block), so `docs/json-output-schema.md` covers both surfaces.
- Window/display enumeration (~100–300 ms) is cached for 2 seconds in serve mode, so
  bursts like `windows` → `screenshot` → `click` pay it once. The CLI always
  enumerates fresh.
- `screenshot` additionally returns the capture as an in-band MCP image content
  block (base64 PNG), so clients get pixels without a follow-up file read.
- `observe_wait` wraps `observe --until` + timeout as a single call; an unmet
  predicate is an `observe_timeout` error (`exitCode` 73 in the envelope).

## Scripting (JSON output)

For automation and scripts, the CLI can emit **exactly one** JSON object to stdout (success or error). Use this to parse results without scraping human output.

- **Per-command:** Add `--json` to any command (e.g. `screencommander doctor --json`).
- **Global:** Use `--output json` before the subcommand, or set `SCREENCOMMANDER_OUTPUT=json` so every command defaults to JSON.
- **One-line output:** Use `--compact` (or `SCREENCOMMANDER_JSON_COMPACT=1`) when output is JSON for smaller, faster-to-parse output.
- **Precedence:** Per-command `--json` overrides root `--output` over env over default (human).

Example:

```bash
# Single command
screencommander doctor --json

# Global JSON for the run
screencommander --output json screenshot --out /tmp/cap.png

# Env var for whole script
export SCREENCOMMANDER_OUTPUT=json
screencommander doctor
screencommander cleanup --json --compact
```

With JSON mode, **stdout is exactly one JSON object**: either a success envelope (`"status": "ok"`, `result`, optional `exitCode`) or an error envelope (`"status": "error"`, `error.code`, `error.message`, `exitCode`). Scripts can read stdout once and branch on `status`. For the full contract (envelope fields and per-command `result` shapes), see [docs/json-output-schema.md](docs/json-output-schema.md).

For maximum speed in scripts, combine `--json --compact --no-postshot` (and optionally `--output json` or the env var) so action commands skip before/after screenshots and emit one-line JSON. Use `--no-diff` when you want captures but do not need frame comparison.

## Metadata Schema

```json
{
  "capturedAtISO8601": "2026-02-20T12:34:56.789Z",
  "displayID": 69733248,
  "displayBoundsPoints": { "x": 0, "y": 0, "w": 1512, "h": 982 },
  "imageSizePixels": { "w": 3024, "h": 1964 },
  "pointPixelScale": 2,
  "imagePath": "/absolute/path/to/Screenshot-20260220-123456.png"
}
```

## Exit Codes

- `10`: screen recording permission denied
- `11`: accessibility permission denied
- `20`: capture failed
- `21`: image write failed
- `30`: metadata read/write failed
- `40`: invalid coordinate
- `41`: mapping failed
- `50`: input synthesis failed
- `60`: invalid arguments or chord parse
- `70`: element not found (`--element`/`--element-id` matched nothing)
- `71`: target app exposes no usable accessibility (AX) tree
- `72`: element not actionable (found but disabled, or action unsupported under `--strict`/`--via`)
- `73`: `observe --until` predicate unmet within `--timeout-ms`
- `80`: window not found (`--window` id/name matched nothing)
- `81`: app not found (`--app` name/pid matched no running app)
- `82`: element ambiguous (`--element` matched multiple best candidates; use `--element-id` or narrow with `--role`/`--app`)
