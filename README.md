# screencommander

<img width="900" height="525" alt="image" src="https://github.com/user-attachments/assets/ea6eccab-5db4-4df1-b8e3-741914167e2d" />

`screencommander` is a macOS 14+ CLI that drives a terminal-first observe -> decide -> act automation loop for agents to operate the desktop through computer use:

1. Observe with Retina-aware screenshot capture
2. Decide with deterministic coordinate mapping from metadata
3. Act with global mouse and keyboard event synthesis

This is also compatible with non-vision model workflows (for example `codex-5.3-codex-spark`) by relying on coordinate + metadata control rather than in-model screenshot understanding.

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

2. Accessibility permission for `click`, `scroll`, `drag`, `move`, `type`, and `key`
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

Behavior:

- Defaults to metadata path `~/Library/Caches/screencommander/last-screenshot.json`.
- Maps screenshot coordinates into global Quartz coordinates deterministically.
- Supports `--button left|right|middle`, `--double`, `--triple`, and `--modifiers cmd,shift,option,ctrl`.
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

Behavior:

- Maps the target point through screenshot metadata, moves the cursor there, then posts a scroll event.
- Uses line units by default; pass `--unit pixels` for pixel scrolling.
- Requires at least one nonzero delta across `--dx` and `--dy`.
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

Behavior:

- Defaults to paste mode (`cmd+v`) for reliable full-text input.
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

### Cleanup

```bash
screencommander cleanup --older-than-hours 24
```

Prunes managed capture artifacts (`png`, `jpg`, `jpeg`, `json`) in `~/Library/Caches/screencommander/captures` older than the configured age.

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
- `80`: window not found (`--window` id/name matched nothing)
- `81`: app not found (`--app` name/pid matched no running app)
