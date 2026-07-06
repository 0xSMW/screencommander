# JSON output schema (scripting)

When you use `--json`, `--output json`, or `SCREENCOMMANDER_OUTPUT=json`, the CLI writes **exactly one** JSON object to stdout: either a success envelope or an error envelope. Scripts can parse stdout and branch on `status`.

## Success envelope

```json
{
  "status": "ok",
  "command": "<command name>",
  "result": { ... },
  "exitCode": 0
}
```

- **status** (string): `"ok"`
- **command** (string): e.g. `"doctor"`, `"screenshot"`, `"click"`
- **result** (object): command-specific payload (see below)
- **exitCode** (number, optional): process exit code (0)

## Error envelope

On failure in JSON mode, the same stdout contains:

```json
{
  "status": "error",
  "command": "<command name>",
  "error": {
    "code": "<stable_code>",
    "message": "<human-readable description>"
  },
  "exitCode": <non-zero>
}
```

- **status** (string): `"error"`
- **command** (string): command that was running
- **error.code** (string): stable snake_case code (see list below)
- **error.message** (string): human-readable message
- **exitCode** (number): process exit code

## Stable error codes

| code | Exit code |
|------|-----------|
| `permission_denied_screen_recording` | 10 |
| `permission_denied_accessibility` | 11 |
| `capture_failed` | 20 |
| `image_write_failed` | 21 |
| `metadata_failure` | 30 |
| `invalid_coordinate` | 40 |
| `mapping_failed` | 41 |
| `input_synthesis_failed` | 50 |
| `invalid_arguments` | 60 |
| `ax_tree_unavailable` | 71 |
| `observe_timeout` | 73 |
| `window_not_found` | 80 |
| `app_not_found` | 81 |

## Command result shapes

### doctor

- **result.permissions** (object): `screenRecordingGranted` (bool), `accessibilityGranted` (bool)
- **result.displays** (array): each `{ displayID, isMain, boundsPoints: { x, y, w, h } }`

### screenshot

- **result.imagePath** (string): absolute path to image
- **result.metadataPath** (string): path to sidecar metadata JSON
- **result.lastMetadataPath** (string): path to last-screenshot.json
- **result.metadata** (object): `capturedAtISO8601`, `displayID`, `displayBoundsPoints`, `imageSizePixels`, `pointPixelScale`, `imagePath`, `windowID` (optional, UInt32), `windowBoundsPoints` (optional, `{x,y,w,h}`)

The `windowID` and `windowBoundsPoints` fields are present only when `--window` was used. Old sidecars without these fields still decode (backward compatible).

For `--window` captures, `displayID` and `displayBoundsPoints` describe the display containing the captured window (falling back to the main display when the window is off-screen); `windowBoundsPoints` carries the window's own frame in global points, and coordinate mapping uses `windowBoundsPoints` when present.

### windows

Lists visible windows (requires Screen Recording permission).

- **result.windows** (array): each element is a `WindowInfo`:
  - `windowID` (number, UInt32)
  - `title` (string)
  - `appName` (string)
  - `pid` (number, pid_t)
  - `boundsPoints` (`{x, y, w, h}` in global screen points)
  - `isOnScreen` (bool)
  - `layer` (number, lower = more foreground)

### focus

Brings an app to the foreground.

- **result.app** (object): `{ pid, name, bundleID? }` — the app that was focused
- **result.priorApp** (object or null): `{ pid, name, bundleID? }` — the previously frontmost app (null if none)

### click

- **result.action** (object): `metadataPath`, `resolved` (inputX, inputY, space, globalX, globalY), `button`, `doubleClick`, `triple`, `primeClick`, `humanLike`, `modifiers`
- **result.preshot** (object or null): `imagePath`, `metadataPath` if pre-shot was captured
- **result.postshot** (object or null): same for post-shot

### scroll

- **result.action** (object): `metadataPath`, `resolved` (inputX, inputY, space, globalX, globalY), `dx`, `dy`, `unit`
- **result.preshot** (object or null): `imagePath`, `metadataPath` if pre-shot was captured
- **result.postshot** (object or null): same for post-shot

### drag

- **result.action** (object): `metadataPath`, `from` (ResolvedCoordinate), `to` (ResolvedCoordinate), `button`, `steps`, `durationMilliseconds`
- **result.preshot** (object or null): `imagePath`, `metadataPath` if pre-shot was captured
- **result.postshot** (object or null): same for post-shot

### move

- **result.action** (object): `metadataPath`, `resolved` (inputX, inputY, space, globalX, globalY), `dwellMilliseconds`
- **result.preshot** (object or null): `imagePath`, `metadataPath` if pre-shot was captured
- **result.postshot** (object or null): same for post-shot
- **result.diff** (object or null): optional frame comparison between `preshot` and `postshot`; omitted or null when disabled with `--no-diff`, when either shot is missing, or when an image cannot be loaded. Shape: `{ changedFraction, changedRegion }`, where `changedFraction` is a number from `0.0` to `1.0` and `changedRegion` is either null or `{ x, y, w, h }` in post-shot pixel coordinates.

### type

- **result.action**: `textLength`, `delayMilliseconds`, `inputMode`
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### key

- **result.action**: `normalizedChord`
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### keys

- **result.action**: `normalizedSteps` (array of strings)
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### elements

- **result.app** (object): resolved target app — `pid` (number), `name` (string), `bundleID` (string or absent)
- **result.windowID** (number, optional): present when `--window-id` was used
- **result.metadataPath** (string or null): screenshot metadata used to compute `boundsPixels`; null when no `last-screenshot.json` exists
- **result.axPrimed** (bool): whether Electron/Chromium AX priming was applied to the app
- **result.truncated** (bool): true when traversal stopped at `--max-elements`
- **result.text** (string, optional): indented text-only tree; present only with `--text`
- **result.elements** (array): one record per AX element, in depth-first tree order:
  - **id** (string): dot-joined child-index path from the app element, e.g. `"0.3.2"`. Positional — re-read the tree instead of caching ids across UI changes.
  - **role** (string), **subrole** (string, optional)
  - **title**, **value**, **description** (strings, optional)
  - **valueTruncated** (bool, optional): present (true) when `value` was cut at `--max-value-length`
  - **enabled** (bool), **focused** (bool, optional)
  - **actions** (array of strings): supported AX actions, e.g. `["AXPress"]`
  - **boundsPoints** (object, optional): `{ x, y, w, h }` in global top-left-origin points
  - **boundsPixels** (object, optional): `{ x, y, w, h }` in the pixel space of `metadataPath`'s screenshot; present only when the element lies within that screenshot's bounds

### observe

`observe` is the one command that does **not** use the single-object envelope. It
streams **NDJSON — one compact JSON object per line** to stdout as UI changes arrive,
and always emits one-line JSON regardless of `--json`/`--compact`/pretty settings.

Each event line:

- **ts** (string): ISO8601 timestamp with fractional seconds
- **event** (string): one of `value_changed`, `focus_changed`, `window_created`,
  `window_moved`, `window_resized`, `title_changed`, `element_destroyed`,
  `app_launched`, `app_activated`, `app_terminated`
- **app** (object): `{ pid, name }` of the observed app (`bundleID` also included when
  known — additive/optional)
- **element** (object, optional): the AX element the event concerns, as an
  `AXElementRecord` (same shape as `elements` records, minus a stable `id`/`boundsPixels`
  — observed elements have no fixed tree position). Absent for `app_*` events.

Termination:

- SIGINT (Ctrl-C) or `--timeout-ms` without `--until` → exit `0`, no extra line.
- `--until` matched (via an initial tree scan or an incoming event) → a final line
  `{ "matched": true, "element": <AXElementRecord?> }`, then exit `0`.
- `--until` unmet within `--timeout-ms` → a standard error envelope
  (`observe_timeout`, exit `73`).

The `--events` selector (`value,focus,window,destroy,app`, default all) controls which
categories stream. The `--until` predicate is a whitespace-joined conjunction of
`key<op>value` conditions — keys `role`/`title`/`value`/`id`, operators `=` (exact) and
`~=` (case-insensitive contains), e.g. `role=AXButton title~=Save`.

### cleanup

- **result.deletedCount** (number)
- **result.deletedBytesApprox** (number)

### sequence

- **result.file** (string): path to sequence file
- **result.steps** (array): each step has `index`, `action`, one of `click`/`scroll`/`drag`/`move`/`type`/`key`/`sleep`, `preshot`, `postshot`, and optional `diff`

## Compact JSON

Use `--compact` or `SCREENCOMMANDER_JSON_COMPACT=1` to get one-line JSON (no pretty-print) for faster parsing and smaller output.
