# screencommander Skill

Use this skill to reliably control a macOS desktop through `screencommander` with a deterministic screenshot -> decide -> act loop.

## When to Use

- You need to observe and interact with macOS UI from Terminal.
- You need reliable clicks, text entry, key chords, or ordered multi-step automation.
- You want immediate visual verification before/after each action.

## Prerequisites

- macOS 14+.
- `screencommander` built/runnable (`swift run screencommander ...`).
- Permissions granted:
  - Screen Recording (for screenshots and default action pre/post shots).
  - Accessibility (for `click`, `type`, `key`, `sequence`).

## Core Rules

1. Treat screenshot metadata as source of truth for coordinate mapping.
2. Use matching image + metadata pairs; do not mix captures.
3. Use Retina-aware screenshot pixel coordinates (image pixel space, top-left origin), not guessed point-space values.
4. Default action behavior includes before/after screenshots (`preshot` + `postshot`).
5. Use `--no-postshot` only when you explicitly want less output/faster runs, but it is not recommended.
6. Default `click` is human-equivalent (compensated); use `--raw` only for strict low-level behavior.
7. Default `type` mode is `paste` (`cmd+v`) for reliable full payload input.

## Fast Start

```bash
swift run screencommander doctor
swift run screencommander screenshot --out /tmp/desk.png
# Inspect /tmp/desk.png and pick x,y in pixel space (top-left origin)
swift run screencommander click <x> <y> --meta /tmp/desk.json
swift run screencommander type "hello world"
swift run screencommander key "enter"
```

## Action Commands (Recommended Defaults)

- Click:
  ```bash
  swift run screencommander click <x> <y> --meta <meta.json>
  ```
- Double click:
  ```bash
  swift run screencommander click <x> <y> --meta <meta.json> --double
  ```
- Type:
  ```bash
  swift run screencommander type "text to input"
  ```
- Key chord:
  ```bash
  swift run screencommander key "cmd+tab"
  ```

All above emit pre/post screenshot paths by default.

## Ordered Multi-Step Automation

Use `sequence` for one-shot ordered workflows (`click` -> `type` -> `key`).

```bash
swift run screencommander sequence --file ./sequence.json
```

Example:

```json
{
  "steps": [
    { "click": { "x": 935, "y": 1074, "meta": "./last-screenshot.json" } },
    { "type": { "text": "hello from sequence", "mode": "paste" } },
    { "key": { "chord": "enter" } }
  ]
}
```

## Troubleshooting

- Missing permission:
  - Run `swift run screencommander doctor`.
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

## Portable Execution Notes

- Replace `swift run screencommander ...` with `screencommander ...` when installed on PATH.
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
