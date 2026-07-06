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
- **Scripting:** Use `--json` or `--output json` (or `SCREENCOMMANDER_OUTPUT=json`) for machine-readable output; stdout is exactly one JSON object (success or error). Use `--compact` for one-line JSON. See README “Scripting (JSON output)” and `docs/json-output-schema.md`.
- `click` coordinates are screenshot pixels by default; do not mix metadata from a different screenshot.
- `click` is a single human-equivalent click by default. When the target app or window is known (`--app` or window metadata), focus is handled through activation before the click instead of spending an extra physical click.
- `click`, `type`, `key`, and `keys` now capture both pre-action and post-action screenshots by default for immediate before/after feedback.
- Disable default before/after capture with `--no-postshot` when scripting speed/output noise matters.
- `sequence` runs bundled actions (`click`, `type`, `key`) in strict order from a JSON file and captures before/after screenshots per step by default.
- `keys` supports explicit step sequences, for example:
  - `screencommander keys press:cmd+tab press:cmd+tab`
- `cleanup` prunes old artifacts from `~/Library/Caches/screencommander/captures` only.
- If permission is missing, commands fail fast with explicit guidance and a System Settings deeplink.
- For installed usage, replace `swift run screencommander ...` with `screencommander ...`.
- Input/send fallback when `key "enter"` or `key "return"` does not send:
  1. Focus compose field with a click, or use `focus --app <name|pid>` first when the app is known.
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
- Focus + click behavior:
  1. Prefer `--app` or window metadata when possible so the engine can activate the target before a coordinate click.
  2. Use `--double` only when the UI itself expects a double-click, such as opening a Finder item.
  3. In Finder app-grid workflows, if icon clicks only select and do not open, use launch fallback:
     ```bash
     open -a "Slack"
     ```
- Human click semantics in CLI:
  - `screencommander click ...` is the human-equivalent single click by default; when a target app/window is known, focus is handled by activation before the click.
  - Use `--raw` only when you want strict low-level event behavior without that compensation.

## Project Mission
Build and maintain `screencommander`, a macOS command-line automation utility that enables a terminal-driven observe -> decide -> act loop. README owns the public product contract, SKILL.md owns the operator runbook, and `docs/json-output-schema.md` owns JSON output shape.

## Execution Protocol
- Use `docs/follow-up-design-issues.md` as the active cleanup-cycle spec while it exists.
- Keep implementation work tied to a current spec, issue, review thread, or explicit user request.
- Do not reintroduce deleted legacy planning docs as sources of truth.
- Keep AGENTS.md focused on repo-agent guidance; put end-user command details in README or SKILL.md.
