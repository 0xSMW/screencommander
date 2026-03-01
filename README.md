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

2. Accessibility permission for `click`, `type`, and `key`
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

Behavior:

- Defaults to metadata path `~/Library/Caches/screencommander/last-screenshot.json`.
- Maps screenshot coordinates into global Quartz coordinates deterministically.
- Captures pre-action and post-action screenshots by default and prints both paths.
- Disable before/after capture with `--no-postshot`.

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

### Keys

```bash
screencommander keys "press:cmd+tab" "press:cmd+tab"
screencommander keys "press:next" "sleep:100" "press:prev"
```

`keys` executes `down`/`up`/`press`/`sleep` steps in strict order.
For repeated modifier-based shortcuts, include modifiers explicitly in each `press` step (for example `press:cmd+tab`). Standalone keys such as `press:next` and `press:prev` do not require modifiers.

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
    { "type": { "text": "hello from sequence", "mode": "paste" } },
    { "key": { "chord": "enter" } }
  ]
}
```

Behavior:

- Executes steps in order.
- Captures pre-action and post-action screenshots around each step by default.
- Disable per-step before/after capture with `--no-postshot`.

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
