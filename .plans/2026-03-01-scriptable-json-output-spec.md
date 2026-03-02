# ScreenCommander Spec: Scriptable CLI with JSON-First Console Output

**Date:** 2026-03-01  
**Scope:** Make the CLI more scriptable by returning JSON directly to the console, reducing I/O and parsing overhead and giving scripts a single, predictable stdout contract.  
**Branch:** This repo

---

## 1. Objective

Improve scriptability and speed when driving `screencommander` from scripts or automation by:

1. **JSON-only stdout in script mode** – When JSON is requested, stdout contains exactly one JSON object (success or error); no mixed human-readable lines or banners.
2. **Optional compact JSON** – One-line JSON for faster parsing and smaller output when speed matters.
3. **Structured errors in JSON mode** – On failure, emit a JSON error object to stdout (or a dedicated stream) so scripts can parse success and failure uniformly.
4. **Global output control** – Allow setting output format once (e.g. global `--output json` or env var) so every command in a script doesn’t need `--json`.
5. **Documented, stable schema** – One envelope and per-command result/error schemas so consumers can rely on a contract.

This spec does **not** change the human-readable default behavior; it extends the existing `--json` behavior and adds options that scripts can opt into.

---

## 2. Current State

### 2.1 What Exists

- **Per-command `--json`** – Every user-facing command has a `--json` flag: `doctor`, `screenshot`, `click`, `type`, `key`, `keys`, `cleanup`, `sequence`.
- **Success envelope** – `CommandRuntime.emitJSON` wraps results in `{ "status": "ok", "command": "<name>", "result": <command-specific> }`.
- **Human output** – When `--json` is false, commands print multiple lines to stdout (paths, counts, preshot/postshot paths, etc.).
- **Errors** – All errors go to stderr via `writeError(...)` and exit code; no JSON error payload. Scripts must infer failure from exit code and parse stderr for messages.
- **JSON formatting** – `JSONEncoder` uses `.prettyPrinted` and `.sortedKeys`; output is multi-line.
- **Banner** – `main.swift` prints a banner to stdout in some code paths; when subcommands run, stdout can still be “clean” for JSON if no banner is printed for that path.

### 2.2 Gaps for Scriptability

| Gap | Impact |
|-----|--------|
| No compact JSON | Larger payloads, slower parsing; scripts often prefer one-line JSON. |
| Errors not in JSON | Scripts can’t get machine-readable error code/message; must parse stderr. |
| No global “JSON mode” | Every invocation needs `--json`; easy to forget in long scripts. |
| Mixed stdout in JSON mode | If any human line or banner is printed before/after JSON, stdout is no longer “exactly one JSON value”. |
| No explicit “stdout is only JSON” guarantee | Docs don’t state that with `--json`, stdout is parseable as a single JSON object (success or error). |
| Exit code not in JSON | Redundant but useful for scripts that capture stdout and still want exit info in the same blob. |

---

## 3. Goals and Non-Goals

### In Scope

- **Single-JSON-object stdout** – When output format is JSON, stdout is exactly one JSON object (success envelope or error envelope). No banner, no “Captured screenshot: …” lines, no trailing newlines beyond the JSON.
- **Compact JSON option** – Flag or option (e.g. `--compact`) to emit one-line JSON (no pretty-print).
- **JSON error envelope** – When in JSON mode and an error occurs, emit one JSON object to stdout (or optionally to stderr) with `status: "error"`, `command`, `error` (code + message), and optional `exitCode`.
- **Global output format** – Top-level option or environment variable (e.g. `SCREENCOMMANDER_OUTPUT=json`) so subcommands default to JSON without per-command `--json`.
- **Schema documentation** – Document the success and error envelope and each command’s `result` shape in a dedicated doc or section (e.g. `docs/json-output-schema.md`).
- **Optional exit code in envelope** – Include `exitCode` in both success and error JSON for convenience.
- **Speed** – Reducing work in script mode: compact JSON is faster to write and parse; ensure no extra human-only work (e.g. building long strings for print) when JSON is requested.
- **README and help menu** – Update the README and the CLI help text (e.g. `screencommander --help` and subcommand help) so users can discover and understand the scriptable JSON output: what it is, when to use it, and how to use `--output json`, `--compact`, and env vars.

### Out of Scope

- Changing default output from human to JSON.
- Adding new commands; this spec is about output format and scriptability of existing commands.
- Binary or non-JSON machine formats (e.g. MessagePack).

---

## 4. Design

### 4.1 Output Modes

- **human** (default) – Current behavior: human-readable lines to stdout, errors to stderr.
- **json** – One JSON object to stdout; success envelope or error envelope. Optionally compact (one line).

When in **json** mode:

- Stdout: exactly one JSON object. No other stdout output (no banner, no “Captured …”).
- Stderr: reserved for non-JSON diagnostics if we ever need them (e.g. debug logs); for this phase, errors are in the JSON object on stdout so stderr can stay empty for normal failures.
- Exit code: unchanged (0 for success, non-zero for failure).

### 4.2 Global vs Per-Command Control

- **Preferred:** Global top-level option `--output <human|json>` (and optionally `--compact` when output is json). Subcommands inherit this unless overridden.
- **Alternative:** Environment variable `SCREENCOMMANDER_OUTPUT=json` (and e.g. `SCREENCOMMANDER_JSON_COMPACT=1`) read by CLI; same effect as global flags.
- **Override:** Per-command `--json` continues to work; when both global and per-command are present, per-command wins (or document a clear precedence: e.g. `--output json` + `--no-json` on a command = human for that command only if we add `--no-json`).

Recommendation: introduce `--output human|json` at the root; subcommands that support JSON check root context. If root is `json`, they emit JSON. Add optional `--compact` at root (only applies when output is json). Keep existing `--json` on each command as a shorthand for “output json for this command” and have it imply root output = json for that run. So:

- `screencommander --output json screenshot` → JSON.
- `screencommander screenshot --json` → JSON (same as above).
- `screencommander --output json --compact doctor` → one-line JSON.

No need for `--no-json` initially; scripts that want human can use `--output human` or omit.

### 4.3 Success Envelope (Existing, Extended)

Current:

```json
{
  "status": "ok",
  "command": "screenshot",
  "result": { ... }
}
```

Add optional fields for scriptability:

- **exitCode** (number): process exit code (0). Omit in human mode; include in JSON mode so a script that only reads stdout can know exit.

Example extended success envelope:

```json
{
  "status": "ok",
  "command": "screenshot",
  "result": { ... },
  "exitCode": 0
}
```

Keep `status`, `command`, `result` required; `exitCode` optional for backward compatibility if we already have consumers.

### 4.4 Error Envelope (New)

When in JSON mode and any error occurs (validation, permission, capture, etc.), emit one object to **stdout** (so stdout is always one JSON object):

```json
{
  "status": "error",
  "command": "screenshot",
  "error": {
    "code": "permission_denied_screen_recording",
    "message": "Screen recording permission is required. Open System Settings..."
  },
  "exitCode": 10
}
```

- **code** – Stable string from `ScreenCommanderError` (e.g. map enum cases to snake_case: `permission_denied_screen_recording`, `invalid_arguments`, `mapping_failed`).
- **message** – Current human-readable description (so scripts can log or display it).
- **exitCode** – Same as process exit code.

In JSON error mode, **stderr** can either stay empty or repeat the message for tools that still tail stderr; spec: “JSON mode: stdout = single JSON object (success or error); stderr may be empty or mirror message.”

### 4.5 Compact JSON

- **Flag:** `--compact` (root-level, or per-command if we want).
- **Behavior:** When output is JSON, set `encoder.outputFormatting = []` (or only `.sortedKeys` for determinism). Single line, no indentation.
- **Use case:** Pipes, `jq -c`, and smaller logs; faster to write and parse.

### 4.6 Guarantee: One JSON Object on Stdout

- When the run is in JSON mode (global or per-command), the process must write exactly one JSON object to stdout and nothing else (no banner, no “Captured …”, no trailing newline beyond the JSON’s newline in compact mode or the final `}\n` in pretty mode).
- If we ever add progress or streaming, they must go to stderr or a separate fd, not stdout.

### 4.7 Documentation and Discoverability

Users and script authors must be able to discover and understand the scriptable JSON behavior without reading the spec or source:

- **README** – Include a clear “Scripting” (or “JSON output”) section that explains: when to use JSON output, `--output json` vs per-command `--json`, `--compact`, env vars, and that stdout is exactly one JSON object. Link to the schema doc for the full contract.
- **Help menu** – The CLI’s own help must explain the capability:
  - **Root** (`screencommander --help`): In the option descriptions for `--output` and `--compact`, state that they enable scriptable machine-readable output and that with `--output json`, stdout is a single JSON object (success or error). If the framework allows, add a brief discussion/example for scripting.
  - **Subcommands**: Each command’s `--json` help string should state that it prints one JSON object to stdout (e.g. “Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.”). This keeps help concise while making the behavior discoverable from the CLI.

### 4.8 Schema Documentation

- Add `docs/json-output-schema.md` (or a section in an existing doc) that defines:
  - Success envelope: `status`, `command`, `result`, optional `exitCode`.
  - Error envelope: `status`, `command`, `error: { code, message }`, optional `exitCode`.
  - For each command: the exact shape of `result` (field names and types), and the list of possible error `code` values for that command.
- Reference this from README and AGENTS.md so script authors have a single contract.

---

## 5. Implementation Plan

### Phase 1: JSON-Only Stdout and Error Envelope (No New Flags Yet)

1. **Audit stdout** – Ensure no command prints anything to stdout when `--json` is true (and no banner for subcommand invocations). Remove or guard any stray `print` in the JSON path.
2. **Error path in JSON mode** – In `CommandRuntime.mapError` (or a shared error handler), when the “current output format” is JSON, encode an error envelope and print it to stdout instead of (or in addition to) writing the human message to stderr. Then exit with the same exit code. Ensure only one JSON object is written.
3. **Make “output format” available** – For this phase, “JSON mode” is simply “subcommand was invoked with `--json`”. Pass a flag or context from each command’s run into the error mapper so the mapper knows whether to emit JSON error to stdout.
4. **Error code mapping** – Add a stable `code: String` for each `ScreenCommanderError` case (e.g. `permissionDeniedScreenRecording` → `"permission_denied_screen_recording"`) and include it in the error envelope.

Deliverable: With `--json`, success = one JSON object on stdout; failure = one JSON object on stdout; no other stdout output; exit codes unchanged.

### Phase 2: Compact JSON and Optional exitCode in Envelope

1. **--compact** – Add `--compact` at root; when set and output is JSON, use no pretty-print. Subcommands that call `CommandRuntime.emitJSON` need to know “compact or not” (e.g. pass a flag or use a shared context).
2. **exitCode in envelope** – Add optional `exitCode` to `CommandEnvelope` and to the error envelope; set it when emitting JSON.

Deliverable: `screencommander screenshot --json --compact` prints one line; envelope may include `exitCode`.

### Phase 3: Global --output and Env Var

1. **Root option** – Add `@Option var output: OutputFormat?` at root (e.g. `OutputFormat: human | json`). If nil, default to human.
2. **Inheritance** – When a subcommand runs, it resolves “effective output format”: subcommand’s `--json` true → json; else root’s `--output`; else human. Pass effective format to the runtime so both success and error paths use it.
3. **Env var** – Read `SCREENCOMMANDER_OUTPUT` (and optionally `SCREENCOMMANDER_JSON_COMPACT`). If set, use as default for `--output` (and `--compact`) when not overridden by flags.
4. **Help** – Document `--output json` and `--compact` and env vars in help and in README/AGENTS.

Deliverable: Scripts can run `SCREENCOMMANDER_OUTPUT=json screencommander doctor` or `screencommander --output json screenshot --out /tmp/a.png` and get only JSON on stdout.

### Phase 4: Schema Doc, Docs, and Help

1. **docs/json-output-schema.md** – Document success envelope, error envelope, and each command’s `result` and possible error codes. Optionally add a minimal JSON Schema (`.json`) or example payloads.
2. **README** – Add or expand a “Scripting” section that explains: JSON output for automation; `--output json` and per-command `--json`; `--compact` for one-line output; env vars `SCREENCOMMANDER_OUTPUT` and `SCREENCOMMANDER_JSON_COMPACT`; that stdout is exactly one JSON object (success or error); and link to `docs/json-output-schema.md`.
3. **Help menu** – Update the CLI help so the capability is visible and explained:
   - **Root help** (`screencommander --help`): Describe `--output` and `--compact` in the option help text, and add a short “Scripting” or “JSON output” paragraph in the abstract or discussion if the parser supports it.
   - **Subcommand help**: Ensure each command’s `--json` help string explains that it prints a single machine-readable JSON object to stdout (and optionally mention `--output json` for all commands). No need to duplicate the full scripting guide in help; keep help concise and point to README/schema for detail.
4. **AGENTS.md** – Add a scripting bullet or reference to the README scripting section and schema.
5. **Tests** – Add tests that run commands with `--json` (and `--compact`) and assert stdout is valid single JSON and that error runs produce the error envelope with expected `code` and `exitCode`.

---

## 6. API / CLI Surface Summary

| Where | Option / Env | Effect |
|-------|----------------|--------|
| Root | `--output <human\|json>` | Default output format for all subcommands. |
| Root | `--compact` | When output is json, emit one-line JSON. |
| Env | `SCREENCOMMANDER_OUTPUT=json` | Same as default `--output json`. |
| Env | `SCREENCOMMANDER_JSON_COMPACT=1` | Same as default `--compact` when output is json. |
| Per-command | `--json` (existing) | Force JSON for this command; overrides default. |

Precedence: per-command `--json` > root `--output` > env `SCREENCOMMANDER_OUTPUT` > default (human).

---

## 7. Error Code Stability

Map `ScreenCommanderError` to stable string codes for the error envelope:

| Enum case | code (snake_case) |
|-----------|--------------------|
| permissionDeniedScreenRecording | permission_denied_screen_recording |
| permissionDeniedAccessibility | permission_denied_accessibility |
| captureFailed | capture_failed |
| imageWriteFailed | image_write_failed |
| metadataFailure | metadata_failure |
| invalidCoordinate | invalid_coordinate |
| mappingFailed | mapping_failed |
| inputSynthesisFailed | input_synthesis_failed |
| invalidArguments | invalid_arguments |

For cases with associated strings (e.g. `captureFailed(String)`), keep the code fixed; put the detail in `message`.

---

## 8. Speed and Scripting Notes

- **Fewer bytes** – Compact JSON reduces stdout size and parse time; scripts that only need one field (e.g. `result.imagePath`) can pipe to `jq -c '.result.imagePath'`.
- **No mixed output** – Guaranteeing “exactly one JSON object” means scripts can do `out=$(screencommander screenshot --json --compact)` and parse `out` without stripping banner or extra lines.
- **Errors without stderr** – Error envelope on stdout lets scripts use one code path: “read stdout, parse JSON, branch on status”; no need to read stderr for message.
- **Existing flags** – `--no-postshot` already reduces work for click/type/key/keys/sequence; document that for maximum speed in scripts, use `--json --compact --no-postshot` (and `--output json` globally if desired).

---

## 9. File and Code Touch Points

- **RootCommand.swift** – Add `--output`, `--compact`; define output context; pass to error mapping.
- **CommandRuntime** – `emitJSON` to accept “compact” flag; add `emitErrorJSON(command:error:exitCode:)`; in `mapError`, when output is JSON, call `emitErrorJSON` and write to stdout (and optionally still write human message to stderr for compatibility).
- **Errors.swift** – Add `var stableCode: String` (or equivalent) to `ScreenCommanderError` for the error envelope.
- **Each CLI command** – Ensure when emitting JSON they don’t print anything else; use shared “output format” from root/context.
- **main.swift** – Ensure banner is not printed when a subcommand is run and output is JSON (or banner goes to stderr in JSON mode).
- **New:** `docs/json-output-schema.md` – Schema and examples.
- **README.md** – Scripting section explaining JSON output, `--output`/`--compact`, env vars, and link to schema.
- **AGENTS.md** – Scripting bullet or pointer to README/schema.
- **Help menu** – Root and subcommand help text: document `--output`, `--compact`, and `--json` so users can discover and understand scriptable JSON output from `screencommander --help` and `screencommander <command> --help`.

---

## 10. Acceptance Criteria

- [x] With `--json` (or `--output json`), stdout is exactly one JSON object (success or error); no other stdout output.
- [x] On failure in JSON mode, the JSON object has `"status": "error"`, `error.code`, `error.message`, and optional `exitCode`.
- [x] `--compact` produces one-line JSON when output is JSON.
- [x] Global `--output json` and env `SCREENCOMMANDER_OUTPUT=json` cause subcommands to emit JSON without per-command `--json`.
- [x] Schema doc exists and lists success/error envelope and each command’s result shape and error codes.
- [x] README includes a Scripting section that explains JSON output, `--output`/`--compact`, env vars, and links to the schema doc.
- [x] Root help (`screencommander --help`) documents `--output` and `--compact`; subcommand help documents `--json` and points users to the idea that stdout is a single JSON object in JSON mode.
- [x] AGENTS.md references the scripting capability and/or README/schema.
- [x] Tests verify single-JSON stdout and error envelope content for at least one success and one failure case.

**Implemented 2026-03-01.** Root `--output`/`--compact` applied via pre-scan in main + env; each subcommand sets `OutputOptions.current` and uses effective format. Error envelope and `stableCode` in Errors.swift; `OutputOptions`, `ErrorEnvelope`, `emitErrorJSON` in RootCommand.swift. Schema in docs/json-output-schema.md; tests in JSONOutputSchemaTests.swift.

---

## 11. References

- Existing JSON envelope: `CommandEnvelope` in `RootCommand.swift`.
- Error handling: `CommandRuntime.mapError`, `writeError` in `Errors.swift`.
- Per-command `--json`: all commands under `Sources/ScreenCommander/CLI/*.swift`.
- INIT.md and AGENTS.md for CLI contract and scripting notes.
