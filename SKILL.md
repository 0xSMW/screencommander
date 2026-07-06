# screencommander Skill

Use this skill to reliably control a macOS desktop through `screencommander` with a deterministic observe -> decide -> act loop. Prefer the accessibility tree over pixels: `elements` reads the screen as structured text in tens of milliseconds, `screenshot --window` captures one window even when it is covered by other windows, and element-targeted actions work without moving the user's cursor.

## When to Use

- You need to observe and interact with macOS UI from Terminal.
- You need to read what is on screen without a screenshot (`elements --text`), watch for UI changes in real time (`observe`), or capture and target a single window (`windows`, `screenshot --window <id>`).
- You need reliable clicks, scrolls, drags, cursor moves, text entry, key chords, or ordered multi-step automation, including element-targeted actions that never touch the pointer (`click --element ... --no-cursor`).
- You want immediate visual verification before/after each action.

## Prerequisites

- macOS 14+.
- `screencommander` installed and available on `PATH`.
- Permissions granted:
  - Screen Recording (for screenshots and default action pre/post shots).
  - Accessibility (for `click`, `scroll`, `drag`, `move`, `type`, `key`, `sequence`, `elements`, `observe`).

## Core Rules

1. Treat screenshot metadata as source of truth for coordinate mapping.
2. Use matching image + metadata pairs; do not mix captures.
3. Use Retina-aware screenshot pixel coordinates (image pixel space, top-left origin), not guessed point-space values.
4. Default action behavior includes before/after screenshots (`preshot` + `postshot`).
5. Use `--no-postshot` only when you explicitly want less output/faster runs, but it is not recommended.
6. Default `click` is human-equivalent (compensated); use `--raw` only for strict low-level behavior.
7. Default `type` mode is `paste` (`cmd+v`) for reliable full payload input.
8. Prefer managed defaults (`~/Library/Caches/screencommander/...`); use explicit `--out`/`--meta` only when you need custom paths or a specific historical capture.

## Fast Start

```bash
screencommander screenshot
# Inspect the printed image path and pick x,y in pixel space (top-left origin)
screencommander click <x> <y>
screencommander type "hello world"
screencommander key "enter"
```

`doctor` reports permissions with traffic lights (`🟢` granted, `🔴` denied).

## Action Commands (Recommended Defaults)

- Click:
  ```bash
  screencommander click <x> <y>
  ```
- Double click:
  ```bash
  screencommander click <x> <y> --double
  ```
- Modifier or middle click:
  ```bash
  screencommander click <x> <y> --button middle --modifiers cmd,shift
  ```
- Scroll below the fold:
  ```bash
  screencommander scroll <x> <y> --dy -5
  ```
- Drag:
  ```bash
  screencommander drag <x1> <y1> <x2> <y2>
  ```
- Move/hover:
  ```bash
  screencommander move <x> <y> --dwell-ms 250
  ```
- Type:
  ```bash
  screencommander type "text to input"
  ```
- Key chord:
  ```bash
  screencommander key "cmd+tab"
  ```

All above emit pre/post screenshot paths by default.

## Reading UI Structure Without Pixels (`elements`)

Use `elements` to read an app's accessibility tree as text — cheaper and more precise than screenshot interpretation when the app exposes AX data:

```bash
screencommander elements --app Safari --text        # indented role "title": value view
screencommander elements --app Safari --json        # full records for scripting
screencommander elements --roles AXButton,AXTextField --visible-only
```

Rules:

1. Prefer `elements --text` for reading screen content; fall back to `screenshot` for AX-opaque apps (exit code `71` means no usable AX tree).
2. Take a `screenshot` first, then `elements`: elements inside that capture get `boundsPixels`, whose center you can pass straight to `click <x> <y>` (default pixel space).
3. Element ids (`0.3.2`) are positional child-index paths — they go stale when the UI changes. Re-run `elements` after each action instead of caching ids.
4. Results are capped (`--max-elements`, default 2000, `truncated: true` when hit); narrow with `--roles`, `--visible-only`, or `--window-id` on busy apps.

## Pointer-Free Input (Element Clicks, `--via`, `--no-cursor`)

Act on apps without coordinates — and without stealing the user's cursor:

```bash
screencommander click --element "General" --app "System Settings" --no-cursor
screencommander click --element-id 0.3.2 --app Safari
screencommander type "user@example.com" --element "Email" --app Safari
screencommander scroll --element "Content" --app Safari --dy -5
```

How it works — a tiered actuator, tried in order, with the outcome reported:

1. `ax`: `AXPress`/`AXShowMenu`/`AXValue` writes — coordinate-free, works on background apps, immune to concurrent user mouse movement.
2. `pid`: the same CGEvents posted only to that app (`CGEventPostToPid`) — the real cursor never moves. Some apps ignore events while unfocused; check the frame diff or re-read `elements` to confirm effect.
3. `global`: the classic path — moves the real cursor.

Rules:

1. Prefer `click --element` over coordinate clicks whenever `elements` shows the target: no stale-coordinate risk, no cursor theft.
2. `--element` matches a case-insensitive title/label substring; disambiguate with `--role button` and `--app <name|pid>`. `--element-id` uses ids from `elements` (positional — always re-read, never cache).
3. Use `--no-cursor` when a human is using the machine: delivery is restricted to `ax` -> `pid` and the pointer never moves.
4. `--via ax|pid|global` forces one tier (no fallback); `--strict` makes downgrades fail with exit `72` instead of being recorded.
5. Read `deliveryMethod` (and `requestedVia`) in JSON output to see which tier actually ran; a downgrade to `global` means the cursor moved.
6. Exit `70` = element not found (re-run `elements`, adjust the query); exit `72` = found but disabled/unsupported for the forced tier.
7. `type --element` sets the value directly (tier `ax`) — ideal for filling fields in background apps; the fallback focuses the element and pastes.
8. Element clicks that fall through to `pid`/`global` land on the element's center; the result's `resolved` reports that point in global points.

## Waiting on UI Changes (`observe`)

Use `observe` instead of screenshot-and-recheck polling when you need to block until something happens. It streams NDJSON events (one per line) and can stop itself when a condition is met:

```bash
# Block until a specific window appears, then return; give up after 10s.
screencommander observe --app Finder --until 'role=AXWindow title~=Downloads' --timeout-ms 10000

# Watch a text field change while typing (Ctrl-C to stop).
screencommander observe --app TextEdit --events value
```

Rules:

1. Prefer `observe --until '<predicate>' --timeout-ms N` over sleep-and-screenshot loops: it returns the instant the condition holds (or exits `73` if the timeout passes unmet).
2. Predicates are whitespace-joined `key<op>value` conditions — keys `role`/`title`/`value`/`id`, ops `=` (exact) or `~=` (case-insensitive contains). All conditions must hold. `role`/`title`/`value` match both the initial tree scan and live events; `id` only matches the initial scan (live events carry no stable tree position), so match late-appearing elements on `role`/`title`/`value`, not `id`.
3. Narrow the feed with `--events` (`value,focus,window,destroy,app`) so you only pay for the changes you care about.
4. On a match, the final line is `{ "matched": true, "element": ... }` (exit `0`). A plain `--timeout-ms` without `--until` just exits `0` when it elapses.

## Ordered Multi-Step Automation

Use `sequence` for one-shot ordered workflows (`click` -> `scroll` -> `move` -> `type` -> `key`).

```bash
screencommander sequence --file ./sequence.json
```

Example:

```json
{
  "steps": [
    { "click": { "x": 935, "y": 1074, "meta": "~/Library/Caches/screencommander/last-screenshot.json" } },
    { "scroll": { "x": 935, "y": 800, "dy": -4 } },
    { "move": { "x": 935, "y": 720, "dwellMS": 100 } },
    { "type": { "text": "hello from sequence", "mode": "paste" } },
    { "sleep": { "ms": 100 } },
    { "key": { "chord": "enter" } }
  ]
}
```

`click`, `scroll`, and `type` steps also accept the pointer-free fields `element`, `elementId`, `role`, `app`, `via`, `noCursor` (click/scroll), and `strict`:

```json
{ "click": { "element": "Save", "app": "TextEdit", "noCursor": true } }
```

## Troubleshooting

- Missing permission:
  - Run `screencommander doctor`.
  - Follow the printed System Settings guidance/deeplink.
- Click appears to target wrong element:
  - Capture a fresh screenshot and use its matching metadata.
  - Verify coordinates in pixel space.
  - Retry with default human-like click (avoid `--raw`).
- Enter/return issues in text fields:
  - Keep `type` in default `paste` mode.
  - Use `key "return"` or app-specific send controls if needed.
- Need deterministic validation after actions:
  - Use default pre/post capture and inspect printed `Preshot`/`Postshot` paths.

## Execution Notes

- This skill assumes `screencommander` is installed and available on `PATH`.
- Keep this skill focused on command orchestration and verification, not app-specific assumptions.

## App Playbooks (Generic)

### List + Detail Surfaces

1. Capture screenshot.
2. Click list item by pixel coordinate using matching metadata.
3. Validate via postshot that detail pane changed.
4. If not changed, recapture and retry with corrected coordinates.

### Compose + Send Surfaces

1. Click compose/input area.
2. `type` message with default paste mode.
3. Trigger send via `key` chord or explicit send control click.
4. Validate in postshot that content moved from input state to sent/applied state.

### Multi-Step Transaction

1. Build `sequence.json` with ordered steps.
2. Run `sequence --file ...`.
3. Inspect per-step preshot/postshot paths to confirm each transition.
4. Re-run only failed/corrected step sets when needed.

### Guarded/Destructive Actions

1. Require a fresh screenshot right before action.
2. Confirm exact target visually from preshot.
3. Execute single intended action (avoid batching until validated).
4. Confirm result in postshot before proceeding to next destructive step.

## Window Targeting (WP2)

### Enumerate Windows

Use `windows` to list all visible windows and their IDs before targeting:

```bash
screencommander windows
screencommander windows --app Safari
screencommander windows --json
```

### Per-Window Screenshot

Capture a single window to get a clean, cropped image and correct coordinate mapping:

```bash
screencommander screenshot --window 12345
screencommander screenshot --window Safari
```

- The sidecar metadata stores `windowID` and `windowBoundsPoints`.
- `click` coordinates from this screenshot map via `windowBoundsPoints` — no manual offset needed.
- Prefer window capture over full-display capture when only one app matters; reduces noise and improves click accuracy.

### Focus an App

Bring an app to the foreground before interacting with it via global input:

```bash
screencommander focus --app Safari
screencommander focus --app 1234
```

- Use before `click`/`type` when the target app may be in the background.
- Reports prior and new frontmost app so you can restore state if needed.

### Error codes

| Exit code | Meaning |
|---|---|
| 70 | Element not found — re-run `elements` and adjust `--element`/`--element-id` |
| 72 | Element not actionable — disabled or the forced tier can't express the action |
| 80 | Window not found — check `windows` output for valid IDs |
| 81 | App not found — verify app name/PID with `windows` or `ps aux` |

## MCP Server Mode (`serve --mcp`)

For agent sessions doing many actions, prefer the MCP server over one-shot CLI calls — it holds one warm engine (no per-action process startup) and returns screenshots as in-band images instead of file paths:

```bash
claude mcp add screencommander -- screencommander serve --mcp
```

- Tools mirror the CLI 1:1 (`screenshot`, `click`, `type`, `key`, `keys`, `scroll`, `drag`, `move`, `elements`, `windows`, `focus`, `observe_wait`, `doctor`, `cleanup`); tool results are the same JSON envelopes documented in `docs/json-output-schema.md`, returned as `structuredContent`.
- `observe_wait` replaces the streaming `observe` command: pass `app`, `timeoutMs`, and optionally `until`; it returns the events seen and the outcome in one call.
- Keep using the CLI for shell scripts and one-off captures.
