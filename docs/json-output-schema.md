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

## Command result shapes

### doctor

- **result.permissions** (object): `screenRecordingGranted` (bool), `accessibilityGranted` (bool)
- **result.displays** (array): each `{ displayID, isMain, boundsPoints: { x, y, w, h } }`

### screenshot

- **result.imagePath** (string): absolute path to image
- **result.metadataPath** (string): path to sidecar metadata JSON
- **result.lastMetadataPath** (string): path to last-screenshot.json
- **result.metadata** (object): `capturedAtISO8601`, `displayID`, `displayBoundsPoints`, `imageSizePixels`, `pointPixelScale`, `imagePath`

### click

- **result.action** (object): `metadataPath`, `resolved` (inputX, inputY, space, globalX, globalY), `button`, `doubleClick`, `primeClick`, `humanLike`
- **result.preshot** (object or null): `imagePath`, `metadataPath` if pre-shot was captured
- **result.postshot** (object or null): same for post-shot

### type

- **result.action**: `textLength`, `delayMilliseconds`, `inputMode`
- **result.preshot** / **result.postshot**: same as click

### key

- **result.action**: `normalizedChord`
- **result.preshot** / **result.postshot**: same as click

### keys

- **result.action**: `normalizedSteps` (array of strings)
- **result.preshot** / **result.postshot**: same as click

### cleanup

- **result.deletedCount** (number)
- **result.deletedBytesApprox** (number)

### sequence

- **result.file** (string): path to sequence file
- **result.steps** (array): each step has `index`, `action`, `click`/`type`/`key`, `preshot`, `postshot`

## Compact JSON

Use `--compact` or `SCREENCOMMANDER_JSON_COMPACT=1` to get one-line JSON (no pretty-print) for faster parsing and smaller output.
