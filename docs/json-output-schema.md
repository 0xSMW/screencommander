# JSON output schema (scripting)

When you use `--json`, `--output json`, or `SCREENCOMMANDER_OUTPUT=json`, the CLI writes **exactly one** JSON object to stdout: either a success envelope or an error envelope. Scripts can parse stdout and branch on `status`.

The three switches do the same thing. A command's `--json` wins over `--output`, which wins over `SCREENCOMMANDER_OUTPUT`. `--output` and `--compact` work before or after the command name. `observe` is the exception and always prints JSON lines (see [observe](#observe)).

A command line that does not parse (an unknown option, a missing argument, a bad value) never reaches the command. When JSON was asked for with `--json`, `--output json` (or `--output=json`), or `SCREENCOMMANDER_OUTPUT=json`, it prints the error envelope with code `invalid_arguments`, the subcommand's name as `command` (`screencommander` when none was named), and exit code 60. Otherwise ArgumentParser prints usage text to stderr and exits 64, with nothing on stdout. `--help` always prints text.

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
- **exitCode** (number): process exit code, always `0`

The MCP server (`serve --mcp`) returns these same envelopes for every tool call, as
the `structuredContent` of the MCP result and as its text content block, so this
document is the contract for both the CLI and MCP. MCP tool names differ for some
commands: `app_state` (state), `list_apps` (apps), `launch_app` (launch), `select_text`
(select-text), `perform_action` (action), and `observe_wait` (observe). There is no MCP
tool for `sequence`, `resume`, or `serve`. The envelope's `command` is the tool name.

MCP-only additions: `screenshot` and `app_state` also return the image as a content
block, and `observe_wait` returns `{ outcome, matched?, events, droppedEvents? }` (see
[MCP notes](#mcp-notes)). MCP stdio requests run in parallel by default. To serialize a
follow-on request, include `params.dependsOn` with the upstream JSON-RPC request id. To
cancel an in-flight request, send `notifications/cancelled` with `params.requestId`.
Queued dependents are canceled with their upstream request.

Optional fields are left out of the JSON when they have no value. They are never `null`.

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
| `capture_timeout` | 22 |
| `metadata_failure` | 30 |
| `invalid_coordinate` | 40 |
| `mapping_failed` | 41 |
| `input_synthesis_failed` | 50 |
| `background_delivery_unavailable` | 51 |
| `target_busy` | 52 |
| `aborted_by_user` | 53 |
| `user_interrupted` | 54 |
| `invalid_arguments` | 60 |
| `element_not_found` | 70 |
| `ax_tree_unavailable` | 71 |
| `element_not_actionable` | 72 |
| `observe_timeout` | 73 |
| `window_not_found` | 80 |
| `app_not_found` | 81 |
| `element_ambiguous` | 82 |
| `stale_metadata` | 83 |
| `window_minimized` | 84 |

## Command result shapes

### doctor

- **result.permissions** (object): `screenRecordingGranted` (bool), `accessibilityGranted` (bool)
- **result.displays** (array): each `{ displayID, isMain, boundsPoints: { x, y, w, h } }`
- **result.privateAPIs** (array): each `{ name, available, usedBy }`. `name` is a private symbol resolved at runtime (`CGEventSetWindowLocation`, `SLEventPostToPid`, `SLEventSetAuthenticationMessage`, `SLSEventAuthenticationMessage`, `SLPSPostEventRecordTo`, `_SLPSGetFrontProcess`, `GetProcessForPID`, `GetProcessPID`, `_AXUIElementGetWindow`, `SLSHWCaptureWindowList`, `SLSGetWindowBounds`), `available` is whether it resolved, and `usedBy` names the tier or feature that needs it.
- **result.presence** (object): the presence process as doctor sees it. Doctor never starts it.
  - **running** (bool), **socketPath** (string), **enabled** (bool): `enabled` is false when `SCREENCOMMANDER_PRESENCE=0`.
  - **serverPID** (number, optional), **tapAvailable** (bool, optional), **aborted** (bool, optional), **overlayWindowIDs** (number array, optional): present when it is running. `tapAvailable` false means the user-input tap could not start, so yielding and the abort key are off. `aborted` true means actions fail with `aborted_by_user` until `resume`.
  - **sessions** (array, optional): each `{ id, pids, userActive, lastUserInputMsAgo?, state, colorIndex }`. `pids` are the leased target pids, and `state` is the cursor state (`idle`, `loading`, or `paused`). A session is listed while it holds a lease, and a lease ends once the session leaves its app alone for the idle period (15 seconds by default).
  - **keepAwake** (bool, optional): true while presence holds its display-awake assertion, which it does whenever a session is listed. False when it holds none, including while a client such as `serve` stays connected with no session. Absent when keep-awake is off in that presence process (`SCREENCOMMANDER_KEEP_AWAKE=0`), when presence is not running, or when it predates this field.
  - **keepAwakeEnabled** (bool): false when `SCREENCOMMANDER_KEEP_AWAKE=0` is set for the process that ran `doctor`.
  - **detail** (string, optional): why the status query did not succeed, such as `Not running (no socket).`
  - **startError** (string, optional): when it is not running, why it could not start. This is a socket directory problem or the error recorded by the last failed start.
- **result.appProfile** (object, optional): present with `doctor --app <name|pid|bundleID|path>` (MCP `doctor` with `app`). Shape: `{ name, bundleID?, pid?, path?, running, profile }`. `profile` has `toolkit` (`native`, `catalyst`, `chromium`, `electron`, `qt`, `java`, `gameEngine`, `unknown`), `engine` (`unity`, `unreal`, or `godot` for game engines), `support` (`supported`, `degraded`, `unsupported`), `reason`, `preferredTier`, `mouseTiers` and `keyboardTiers` (background ladder order after private-symbol checks, where `ax` applies to element actions only), `authenticatedKeyboard`, `evidence` (bundle paths or Info.plist keys), `bundleID`, `version`, `bundlePath`, and `cached` (true when the classification came from `<state>/profiles/`). Classification reads the bundle and sends no input. An `unsupported` app refuses background coordinate and keyboard events with `background_delivery_unavailable` unless `--via` forces a tier or `--foreground` is set. AX actions are still tried.

### screenshot

- **result.imagePath** (string): absolute path to image
- **result.metadataPath** (string): path to sidecar metadata JSON
- **result.lastMetadataPath** (string): path to last-screenshot.json
- **result.metadata** (object): `capturedAtISO8601`, `displayID`, `displayBoundsPoints`, `imageSizePixels`, `pointPixelScale`, `imagePath`, `windowID` (optional, UInt32), `windowBoundsPoints` (optional, `{x,y,w,h}`)

The `windowID` and `windowBoundsPoints` fields are present only when `--window` was used. Old sidecars without these fields still decode (backward compatible).

A window that is not on screen (minimized, its app hidden, or on another Space) is captured through the window server. When that fails, the error is `window_minimized` for a minimized window and `capture_failed` for the others. With Stage Manager on, a window in another stage, or a window minimized into the strip, comes back as the strip thumbnail, a small image drawn in perspective, and `windowBoundsPoints` holds the thumbnail's bounds. Neither ScreenCaptureKit nor the window server returns a full-size image of such a window. Its accessibility tree reads normally.

For `--window` captures, `displayID` and `displayBoundsPoints` describe the display containing the captured window (falling back to the main display when the window is off-screen). `windowBoundsPoints` carries the window's own frame in global points, and coordinate mapping uses `windowBoundsPoints` when present.

### windows

Lists on-screen windows. Needs Screen Recording permission.

- **result.windows** (array): each element is a `WindowInfo`:
  - `windowID` (number, UInt32)
  - `title` (string)
  - `appName` (string)
  - `pid` (number, pid_t)
  - `boundsPoints` (`{x, y, w, h}` in global screen points)
  - `isOnScreen` (bool): always true here, since the list holds on-screen windows only
  - `layer` (number, lower = more foreground)

### focus

Brings an app to the front.

- **result.app** (object): `{ pid, name, bundleID? }`, the app that was focused
- **result.priorApp** (object, optional): `{ pid, name, bundleID? }`, the previously frontmost app. Absent when there was none.

### Delivery receipt fields

`result.action` of `click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `select-text`, and `action` carries these fields. Sequence steps carry them inside each step's action result.

- **deliveryMethod** (string): the tier that delivered the input. One of `"ax"`, `"window"`, `"focusAssisted"`, or `"global"`. `"global"` appears only with `--foreground`. `select-text` and `action` always report `"ax"`.
- **requestedVia** (string, optional, `click`, `scroll`, `type`): the tier forced with `--via`. `--via pid` is reported as `"window"`.
- **focus** (object): `{ preserved, frontmostBefore, frontmostAfter, focusedWindowBefore, focusedWindowAfter, focusedElementBefore, focusedElementAfter, cursorMoved, guardRestored? }`, sampled before delivery and again about 60 ms after.
  - **preserved** (bool): false when the frontmost app, its focused window, or its focused element changed. A window or element that AX could read on only one side does not count as a change.
  - **frontmostBefore**, **frontmostAfter** (string or absent): bundle ID of the frontmost app, or its name when it has no bundle ID.
  - **focusedWindowBefore**, **focusedWindowAfter** (string or absent): identity of the frontmost app's focused window, read through AX. `window:<id>` when AX maps it to a window ID, otherwise `ax:<hash>`. Never the title.
  - **focusedElementBefore**, **focusedElementAfter** (string or absent): identity of the frontmost app's focused UI element, `<role>:<hash>`, for example `AXTextArea:6370a5d9`. Never the value.
  - **cursorMoved** (bool): whether this action moved the hardware cursor. It is true only for `--foreground` (global) delivery when the position changed by more than half a point. Background delivery never moves the cursor, so it is false there even if the user moves their own mouse. Cursor movement never affects `preserved`.
  - **guardRestored** (bool, optional): true when this action's target took focus during the action and the presence focus guard put the previous app back before the after-sample. A restore for any other app, such as another session's target, does not count. `preserved` is then false although the frontmost app ends up unchanged. Absent when presence did not take part, when the action has no target app (a `--foreground` system key), or when the presence process predates this field.
- **verified** (bool or the string `"unknown"`): whether the effect was read back. Element `type` compares the element value with the text (exact for `ax`, contains for the keyboard tiers, `"unknown"` when a keyboard tier's read-back does not contain it). Page scrolls (`--direction`) compare the scroll bar position. `select-text` compares the selected range. Everything else reports `"unknown"`.
- **presence** (string): `"active"` when the presence process took part: it checked the abort key and the user's activity, and leased the target for the session when the action has a target app. `--foreground` actions report `"active"` too, without the agent cursor or the focus guard. `"unavailable"` when it could not be reached and input was delivered without it, `"disabled"` when `SCREENCOMMANDER_PRESENCE=0` turns presence off.

### click

- **result.action** (object): `metadataPath` (string, coordinate clicks only), `resolved` (inputX, inputY, space, globalX, globalY, absent for AX-delivered element clicks. Element clicks delivered through an event tier report the element center in `points` space.), `button`, `doubleClick`, `triple`, `primeClick`, `humanLike`, `modifiers`, plus the [delivery receipt fields](#delivery-receipt-fields)
  - **deliveryMethod**: element clicks try `"ax"` first. Coordinate clicks start at the event tiers and use `"global"` only with `--foreground`. A `deliveryMethod` differing from the preferred tier records a downgrade (not an error unless `--strict`).
  - **element** (object, optional): the resolved `AXElementRecord` (same shape as `elements` records), present for `--element`/`--element-id` clicks
  - **verifiedTarget** (object, optional): the `AXElementRecord` hit-tested at the mapped point when `--verify-target` was passed (may be absent when nothing was hit)
  - **axError** (string, optional): set when an `ax` press got no confirmation from the app, for example `"cannotComplete"` after a timeout. The press may have run, so no event tier was tried. `verified` is then `true` when the element's value changed, else `"unknown"`. Absent when the app confirmed or refused the press.
  - **metadataFreshness** (object, optional): present for coordinate clicks that used metadata. Shape: `{ status, scope, reason }`, where `status` is `"fresh"`, `"stale"`, or `"unknown"`, `scope` is `"display"` or `"window"`, and `reason` is a human-readable explanation. `--strict-metadata` turns known stale metadata into `stale_metadata` before input injection.
- **result.preshot** (object, optional): `{ imagePath, metadataPath }` of the main-display capture taken before the action. Absent with `--no-postshot`, when the capture failed, and always over MCP. These captures never replace last-screenshot.json.
- **result.postshot** (object, optional): the same for the capture taken after the action
- **result.preshotError**, **result.postshotError** (object, optional): `{ code, message }` when that capture was requested and failed, for example `capture_timeout` when ScreenCaptureKit did not answer. The action itself ran and `result.action` reports it. A capture gives up after at most 11 seconds.
- **result.diff** (object, optional): frame comparison between `preshot` and `postshot`. Absent with `--no-diff`, when either shot is missing, or when an image cannot be loaded. Shape: `{ changedFraction, changedRegion }`, where `changedFraction` is a number from `0.0` to `1.0` and `changedRegion` is `{ x, y, w, h }` in post-shot pixel coordinates, absent when nothing changed. `--diff-grid` and `--diff-threshold` tune the calculation and leave the shape unchanged.

### scroll

- **result.action** (object): `metadataPath` (string, coordinate scrolls only), `resolved` (inputX, inputY, space, globalX, globalY. Element scrolls report the element center in `points` space.), `dx`, `dy`, `unit`
  - **requestedVia** (string, optional), **deliveryMethod** (string), **element** (object, optional): same semantics as `click`. Only page scrolls (`--direction`) have an `ax` tier.
  - **direction** (string, optional), **pages** (number, optional): set for `--direction up|down|left|right --pages <n>` element scrolls. Via `ax`, **axMethod** names the AX route (`AXScrollDownByPage` and friends, `AXIncrementPage`/`AXDecrementPage`, or `AXValue`) and `dx`/`dy` are 0. Via a wheel tier, `dx`/`dy` are the total pixel deltas sent. `verified` compares the scroll bar position before and after when AX exposes one.
  - **metadataFreshness** (object, optional): same semantics as `click`, present for coordinate scrolls that used metadata.
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### drag

- **result.action** (object): `metadataPath`, `from` (ResolvedCoordinate), `to` (ResolvedCoordinate), `button`, `steps`, `durationMilliseconds`, `metadataFreshness` (same semantics as click), plus the [delivery receipt fields](#delivery-receipt-fields) except `requestedVia`
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### move

- **result.action** (object): `metadataPath`, `resolved` (inputX, inputY, space, globalX, globalY), `dwellMilliseconds`, `metadataFreshness` (same semantics as click), plus the [delivery receipt fields](#delivery-receipt-fields) except `requestedVia`
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### type

- **result.action**: `textLength`, `delayMilliseconds`, `inputMode`, plus the [delivery receipt fields](#delivery-receipt-fields)
  - **deliveryMethod** (string): `"ax"` when the text went in through accessibility, into the element or into the app's focused text field. Chromium and Electron apps try key events first, so they report `"ax"` only with `--via ax` or when no key tier could run. Otherwise the keyboard tier that sent Unicode key events: `"window"`, `"focusAssisted"`, or `"global"` with `--foreground`.
  - **inputMode** (string): what put the text in, whatever `--mode` asked for. `"unicode"` for key events, `"paste"` for a Command-V paste, and `"ax"` when tier `ax` wrote the text through accessibility. The `window` and `focusAssisted` tiers always report `"unicode"`, because they never paste. `"paste"` appears only with `--mode paste` and `"global"` delivery, the only case that touches the clipboard.
  - **element** (object, optional): same as `click`. Present when `--element` or `--element-id` picked the target. Absent when the text went to the app's focused text field or to the app as key events.
  - **keyWindowID** (number, optional): the window the key events went to, when that is known. It is the window that had to be made key (`--window-id`, or the window that holds the target element), else the app's key window as accessibility reports it. Absent for `"ax"` and `"global"` delivery.
  - **replace** (boolean, optional): `true` when `--replace` asked for the whole value to be replaced. Absent otherwise, which means the text was inserted at the caret, replacing only the selection.
  - **verified**: `true` when a read-back showed the expected value (after an `ax` write), or after key events into an element, a changed value that equals the expected text or holds the text at the old caret. Text already in the field does not count. `false` when an `ax` write left a different value than expected, for example after a formatter rewrote it. `"unknown"` for a secure text field, for key events into a value that cannot be read, and for keys typed without an element.
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### key

- **result.action**: `normalizedChord`, plus the [delivery receipt fields](#delivery-receipt-fields) except `requestedVia`
  - **menuItem** (string, optional): present when a background Command chord was resolved to a menu item and pressed through accessibility, as `Menu > Item` (for example `Edit > Select All`). `deliveryMethod` is then `"focusAssisted"` when the window was made key for the press, or `"ax"` when the item was pressed with no key window. Absent when the chord was sent as key events.
  - **verified**: `true` for a menu item pressed in a key window (it existed, read enabled, and took the press or the chord). `"unknown"` for a chord sent as key events.
  - **keyWindowID** (number, optional): same as `type`.
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### keys

- **result.action**: `normalizedSteps` (array of strings), plus the [delivery receipt fields](#delivery-receipt-fields) except `requestedVia`
  - **keyWindowID** (number, optional): same as `type`.
- **result.preshot** / **result.postshot**: same as click
- **result.diff**: same as click

### elements

- **result.app** (object): the resolved target app, `{ pid, name, bundleID? }`
- **result.windowID** (number, optional): present when `--window-id` was used
- **result.metadataPath** (string, optional): screenshot metadata used to compute `boundsPixels`. Absent when no `last-screenshot.json` exists or with `--profile text`.
- **result.axPrimed** (bool): whether Electron/Chromium AX priming was applied to the app
- **result.truncated** (bool): true when traversal stopped early or a read was incomplete
- **result.visitedCount** (number, optional): nodes visited before filtering
- **result.partialReason** (string, optional): why a read is incomplete (`max_elements`, `max_visited`, `timeout`, `cancelled`, or `ax_error`)
- **result.profile** (string, optional): `"text"` with `--profile text`, which skips bounds and actions. Scalar fields remain available, and an empty actions array then means the actions were not read.
- **result.text** (string, optional): indented text-only tree, present only with `--text`
- **result.snapshotId** (string, optional, MCP): reference to this complete read. At most eight are kept per engine session, within an estimated 8 MiB budget.
- **result.baseSnapshotId** (string, optional, MCP): the baseline of a delta. `elements` then holds only changed and added records.
- **result.removedIds** (string array, optional, MCP): element IDs absent from the new complete read
- **result.resetReason** (string, optional, MCP): `snapshot_unavailable`, `scope_changed`, `incomplete_read`, or `snapshot_too_large`. `elements` is then the full available read, not a delta. Incomplete reads get no new snapshot ID.
- **result.elements** (array): one record per AX element, in depth-first tree order:
  - **id** (string): the element ID, a dot-joined child-index path from the app element, e.g. `"0.3.2"`. It is a position, so read the tree again after the UI changes instead of caching IDs.
  - **role** (string), **subrole** (string, optional)
  - **title**, **value**, **description** (strings, optional)
  - **valueTruncated** (bool, optional): present (true) when `value` was cut at `--max-value-length`
  - **enabled** (bool), **focused** (bool, optional)
  - **actions** (array of strings): supported AX actions, e.g. `["AXPress"]`
  - **boundsPoints** (object, optional): `{ x, y, w, h }` in global top-left-origin points
  - **boundsPixels** (object, optional): `{ x, y, w, h }` in the pixel space of `metadataPath`'s screenshot, present only when the element lies within that screenshot's bounds

MCP `elements` accepts `snapshot: true` or `since: "<snapshotId>"`. Deltas describe record changes, not durable element identity. Rebuild the tree by deleting `removedIds` and replacing or inserting changed records by ID. A partial read never establishes that an element is absent outside the part it read. `text`, when requested for a delta, renders only the changed records.

### state

One call for an app window: a window capture plus its AX tree. The capture also becomes last-screenshot.json, so coordinate actions map against it.

- **result.app** (object): `{ pid, name, bundleID? }`
- **result.windowID** (number): the captured window (`--window-id`, else the app's frontmost window)
- **result.imagePath**, **result.metadataPath** (strings), **result.screenshot** (object): the capture and its metadata, same shape as `screenshot`'s `metadata`
- **result.tree** (object): same shape as `elements`, with the same element ids. `boundsPixels` maps against this capture. The CLI returns the full tree. MCP `app_state` keeps a snapshot per window and returns a delta (`baseSnapshotId`, changed records, `removedIds`) on later calls. `full: true` returns the whole tree, and `since` picks the baseline. MCP also returns the image as a content block.

### apps

- **result.running** (array): each `{ name, bundleID?, pid, frontmost, windowCount, activationPolicy, bundlePath? }`. `activationPolicy` is `regular` or `accessory`. `windowCount` counts on-screen normal-layer windows.
- **result.installed** (array, absent with `--running-only` or MCP `includeInstalled: false`): each `{ name, bundleID?, path, version?, running }`. The scan covers `/Applications`, `/System/Applications`, and `~/Applications` one folder deep, stops at 2000 bundles, and is cached for 60 seconds per process.
- **result.installedTruncated** (bool, optional): true when the scan hit its cap

`--filter` (MCP `filter`) keeps apps whose name or bundle ID contains the text.

### launch

- **result.app** (object): `{ pid, name, bundleID? }`
- **result.path** (string): the launched bundle
- **result.alreadyRunning** (bool): true when the app was already running, in which case nothing was launched
- **result.ready** (bool): the app finished launching or answered AX before `--timeout-ms`
- **result.focus** (object): the focus receipt described under [delivery receipt fields](#delivery-receipt-fields). `preserved` false means the frontmost app, its focused window, or its focused element changed.
- **result.presence** (string): `"active"` when the presence focus guard covered the launch, `"unavailable"` when the presence process could not be reached, `"disabled"` when presence is off (`SCREENCOMMANDER_PRESENCE=0`) or the app was already running

### select-text

- **result.action**: `element`, `range` (`{ location, length }` in UTF-16 code units, the one requested or found with `--text`), `selectedRange` and `selectedText` (read back after the write, optional), `deliveryMethod` (`"ax"`), `focus`, `verified` (true when `selectedRange` equals `range`), `presence`. There is no `preshot`, `postshot`, or `diff`.

### action

- **result.action**: `name` (the AX action performed, normalized, e.g. `AXShowMenu`), `element`, `deliveryMethod` (`"ax"`), `focus`, `verified` (`"unknown"`), `presence`. There is no `preshot`, `postshot`, or `diff`. Names the element does not list fail with `element_not_actionable`, and the message lists the ones it does.

### resume

CLI only. There is no MCP tool.

- **result.resumed** (bool): true when a running presence process answered the resume request, whether or not input had been stopped
- **result.presence** (string): `"active"` when the presence process answered, `"unavailable"` when none is running
- **result.wasAborted** (bool, optional): whether agent input was stopped before this call

### observe

`observe` is the one command that does **not** use the single-object envelope. It
streams **NDJSON, one compact JSON object per line**, to stdout as UI changes arrive,
whatever `--json` or `--compact` say. Errors still print a single error envelope.

Each event line:

- **ts** (string): ISO8601 timestamp with fractional seconds
- **event** (string): one of `value_changed`, `focus_changed`, `window_created`,
  `window_moved`, `window_resized`, `title_changed`, `element_destroyed`,
  `app_launched`, `app_activated`, `app_terminated`
- **app** (object): `{ pid, name, bundleID? }` of the observed app
- **element** (object, optional): the AX element the event concerns, as an
  `AXElementRecord` (same shape as `elements` records, but with an empty `id` and no
  `boundsPixels`, since observed elements have no fixed tree position). Absent for
  `app_*` events.

Termination:

- SIGINT (Ctrl-C) or `--timeout-ms` without `--until` → exit `0`, no extra line.
- `--until` matched (via an initial tree scan or an incoming event) → a final line
  `{ "matched": true, "element": <AXElementRecord?> }`, then exit `0`.
- `--until` unmet within `--timeout-ms` → a standard error envelope
  (`observe_timeout`, exit `73`).

The `--events` selector (`value,focus,window,destroy,app`, default all) controls which
categories stream. The `--until` predicate is a whitespace-joined conjunction of
`key<op>value` conditions, with keys `role`, `title`, `value`, and `id` and operators `=` (exact) and
`~=` (case-insensitive contains), e.g. `role=AXButton title~=Save`. `role`, `title`, and `value`
are matched against both the one-shot initial tree scan and every live event. `id` is
matched **only on the initial scan**, because live event records carry no stable tree position
(their `id` is empty). An `id` condition on an element that appears *after* observation
starts can never match and will run to `--timeout-ms` (exit `73`). Match late-appearing
elements on `role`/`title`/`value`.

### cleanup

- **result.deletedCount** (number)
- **result.deletedBytesApprox** (number)

### sequence

CLI only. There is no MCP tool.

- **result.file** (string): absolute path of the sequence file
- **result.steps** (array): one entry per completed step, with `index` (from 1), `action` (the step type), the step's result under one of `click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `selectText`, `performAction`, `launch`, or `sleep`, and optional `preshot`, `postshot`, `preshotError`, `postshotError`, and `diff` as described for click. An `action` step's result is under `performAction`, and a `sleep` step's is `{ ms }`. The first failing step ends the run with that step's error envelope, so `steps` appears only when every step succeeded. A file with an unknown step, an unknown field, a wrong type, or a number out of range fails with `invalid_arguments` before any step runs. The message names the step number and the field.

## Compact JSON

Use `--compact` or `SCREENCOMMANDER_JSON_COMPACT=1` to get one-line JSON (no pretty-print) for faster parsing and smaller output.

## MCP notes

### Post-action observation

`click`, `type`, `key`, `keys`, `scroll`, `drag`, `move`, `select_text`, and `perform_action` accept an optional `postObserve` object. Required `app` selects the app to read. Optional `profile` (`full`/`text`), `since`, `maxElements` (default 200), `maxVisited` (2000), and `timeoutMs` (500) configure the read. Options are validated before delivery. `result.observation` has the elements schema above and requests a snapshot. `result.observationError` means delivery succeeded but observation failed. The action stays successful so a caller does not repeat the input. This is an immediate post-delivery read, not a guarantee that the UI has settled.

### observe_wait

The result is `{ outcome, matched?, events, droppedEvents? }`. `outcome` is `matched`, `timed_out`, `timed_out_unmet`, `interrupted`, or `completed`, and `events` holds the observe event objects described above. On `observe_wait` predicate timeout, `isError` remains true and `exitCode` remains 73. Its error envelope additionally includes `result: {outcome, matched?, events, droppedEvents?}` so observed progress is retained. Event storage retains the newest 500 records in chronological order.
