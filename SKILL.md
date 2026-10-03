# screencommander runbook

screencommander drives macOS apps from the terminal. It reads an app's window and accessibility tree, then clicks, types, and presses keys in that app while the app stays in the background. The user's frontmost app and real cursor stay where they are, so the user can keep working while you act.

## Setup check

Run `screencommander doctor` once at the start. It reports the Screen Recording and Accessibility permissions, the private symbols background delivery needs, and the presence process that runs the agent cursor, leases, focus guard, and abort key. You cannot grant a permission yourself. If one is missing, give the user the System Settings path that `doctor` prints and wait.

## The loop

1. Observe with `state --app <name>`. It captures the app's front window without activating it, keeps the capture as the coordinate reference, and prints the tree as `[id] role "title" = value @(x,y wxh)` lines.
2. Act on an element by id or label, with `--app`.
3. Read the result. Pass `--json` to get the fields described in [Reading a result](#reading-a-result).
4. Observe again before the next decision. Ids are positional child-index paths, so any UI change can shift them. Never reuse an id after the UI changed.

```bash
screencommander state --app TextEdit
screencommander click --element-id 0.2.1 --app TextEdit --json
screencommander type "hello world" --element-id 0.2.1 --app TextEdit --json
screencommander key cmd+s --app TextEdit --json
screencommander state --app TextEdit
```

Input goes to the target app in the background. Do not run `focus` and do not pass `--foreground` unless a result fails with `background_delivery_unavailable` and the task cannot be done another way. `--foreground` activates the app and moves the user's real cursor. It still takes the lease, stops for the abort key, and waits until the user has stopped typing or moving the mouse anywhere. Tell the user before you use it.

## Targets

Always pass `--app <name|pid>`. Add `--window-id <id>` when the app has several windows and it matters which one gets the input. Keys then go to that window, which is made key first, or the action fails with `background_delivery_unavailable`.

Without a target, input lands somewhere you did not choose:

- Element actions, `select-text`, `action`, and `elements` go to the frontmost app, which is usually the one the user is working in.
- `type`, `key`, and `keys` go to the window of the last `state` or `screenshot --window` capture, else to the frontmost app.
- Coordinate `click`, `scroll`, `drag`, and `move` go to the window of the last `state` or `screenshot --window` capture, else to whatever window is under the point.
- `state` and `observe` refuse to run without `--app`.

Find and start targets:

```bash
screencommander apps --running-only --filter notes
screencommander windows --app Notes
screencommander launch --app Notes
```

App names match exactly first, then by prefix. An ambiguous name fails with `invalid_arguments` and lists the candidates, so pass the pid instead. `launch` starts an app without activating it and waits until it runs. It reports an app that is already running instead of relaunching it, and the focus guard puts the user's app back if the new app takes focus. Run `state` after it.

## Observing

- `state --app <name>` captures one window and prints its tree with ids. `--window-id` picks another window. `--json` adds `boundsPixels` to each element inside the capture.
- `state --app <name> --text` and `elements --app <name> --text` print text only, as `role "title": value` lines with no ids. Use them to read content, not to pick targets.
- `elements --app <name>` reads the tree without a capture. On busy apps narrow it with `--roles AXButton,AXTextField`, `--visible-only`, `--window-id`, or `--all-windows`. It stops at `--max-elements` (default 2000) and then reports `truncated`.
- `screenshot --window <id>` captures one window even when other windows cover it. Use the id from `windows`. A name matches by app-name prefix and can pick the wrong app.

An id from any of the app's windows resolves, so ids from `state --window-id` or `elements --all-windows` work with `--element-id`. `--element "<label>"` searches the app's focused window, or the `--window-id` window when you pass one.

Coordinates are pixels in the last capture, top-left origin, at Retina resolution. Take them from the image or from the center of an element's `boundsPixels` in `state --json`. The `@(x,y wxh)` in the human output is global points and is not a click coordinate. After a window capture, coordinate actions go to that window even if something else now covers the point. If a result's `metadataFreshness` says `stale`, capture again. `--strict-metadata` makes a stale capture fail with `stale_metadata` instead.

## Waiting for the UI

Use `observe` instead of polling with screenshots:

```bash
screencommander observe --app Finder --until 'role=AXWindow title~=Downloads' --timeout-ms 10000
```

A predicate is space-separated `key=value` (exact) or `key~=value` (case-insensitive contains) conditions on `role`, `title`, `value`, or `id`, and all must hold. `id` matches only the tree as it was when `observe` started, so match elements that appear later by `role`, `title`, or `value`. On a match the last line is `{"matched": true, "element": ...}` and the exit code is 0. An unmet `--until` exits with `observe_timeout`. `--events value,focus,window,destroy,app` limits the stream.

## Acting

Target elements by `--element-id`, or by `--element "<label>"` narrowed with `--role`. Use coordinates only for things the tree does not expose.

| Goal | Command |
|---|---|
| Press a button, pick a row or tab | `click --element-id <id> --app <name>` |
| Open a context menu | `click --element-id <id> --button right --app <name>` |
| Double-click or modifier-click | `click --element-id <id> --double --app <name>`, `click --element-id <id> --modifiers cmd --app <name>` |
| Insert text | `type "<text>" --element-id <id> --app <name>` |
| Replace a field's whole value | `type "<text>" --element-id <id> --replace --app <name>` |
| Shortcut or special key | `key cmd+s --app <name>`, `key return --app <name>` |
| Hold keys | `keys down:shift press:down press:down up:shift --app <name>` |
| Scroll a list or page | `scroll --element-id <id> --direction down --pages 2 --app <name>` |
| Scroll at a point | `scroll <x> <y> --dy=-5 --app <name>` |
| Select text | `select-text --element-id <id> --text "hello" --app <name>` or `--range 0,5` |
| Any other accessibility action | `action --element-id <id> --name AXIncrement --app <name>` |
| Hover or drag | `move <x> <y> --dwell-ms 250 --app <name>`, `drag <x1> <y1> <x2> <y2> --app <name>` |
| Fixed multi-step run | `sequence --file steps.json` |

`action` accepts only names in the element's `actions` list from `elements --json`, and the `AX` prefix is optional. Double, triple, modifier, and middle clicks cannot go through accessibility, so they land as window events at the element's center.

### Text input

- `type` inserts at the field's caret and replaces only the selected text, the same as typing on the keyboard. `--replace` replaces the whole value and needs an element or a focused text field.
- In native apps `type` writes through accessibility first and reads the value back. If the field ignores the write and its value is unchanged, `type` falls back to key events at the same caret.
- In Chromium and Electron apps `type` sends key events first, because a web page's editor never sees accessibility writes. It writes through accessibility only when no key tier can run.
- `type` never touches the clipboard. `--mode paste` uses it only together with `--foreground`.
- Without an element, `type` writes into the app's focused text field, or sends key events to wherever the app's focus is. Prefer `--element-id`, or check that the field is focused first.
- Check `verified` after every `type`. `false` after an accessibility write means the field rewrote the text, for example a formatter. Re-read `state` and do not type again, which would duplicate the text.

### Keyboard shortcuts

- In the background, `key` presses a Command chord that matches one of the app's menu items through accessibility, and the result's `menuItem` names it as `Menu > Item`. Any other Command chord goes to the app's window, which is made key for the moment without activating the app.
- A chord that is not a menu item fails with `background_delivery_unavailable` when the app has no on-screen window. A menu item that stays disabled fails with `element_not_actionable`.
- `keys` does not look up menu items, so send a single shortcut with `key`.
- System and media keys such as `volumeup`, `play`, and `launchpad`, system shortcut aliases such as `spotlight` and `missioncontrol`, and chords macOS takes for itself (`cmd+tab`, `cmd+space`, `cmd+option+esc`, Lock Screen, Log Out, and the `cmd+shift+3`, `4`, and `5` screenshot chords) are refused in the background with `background_delivery_unavailable`. Do not reach for `--foreground` to switch apps unless the user asked.

### Sequences

`sequence` runs fixed steps in order. Each step has one key: `click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `selectText`, `action`, `launch`, or `sleep`. Steps take the same targets as the commands, spelled `app`, `windowId`, `element`, `elementId`, `role`, `session`, and `agentCursor`, and the MCP tools' field names such as `durationMs` and `delayMs`. A misspelled field fails the whole file before any step runs, and the error names the step and the field. Ids can change between steps, so prefer labels.

```json
{
  "steps": [
    { "click": { "element": "Search", "role": "textfield", "app": "Notes" } },
    { "type": { "text": "groceries", "app": "Notes" } },
    { "sleep": { "ms": 200 } },
    { "key": { "chord": "return", "app": "Notes" } }
  ]
}
```

The first failing step stops the run, and the error does not say which earlier steps ran. Re-observe before you retry.

## Reading a result

- `deliveryMethod` is the tier that delivered the input. `ax` is an accessibility action or write with no events. `window` is events posted to the app's window. `focusAssisted` makes the window key without activating the app, then posts the same events. `global` activates the app and moves the real cursor, and only runs with `--foreground`.
- `verified` is `true` or `false` when screencommander read the effect back, and `"unknown"` when it did not. Read-back happens for `type`, `select-text`, `scroll --direction`, and a `key` that pressed a menu item in a key window. `type` with key events reports `true` or `"unknown"`, never `false`. `scroll --direction` reports `false` when the scroll position did not move, often because the list is already at the end. Every other action, including `click`, `action`, `drag`, `move`, and `keys`, reports `"unknown"`, which means the events went out and nothing confirmed them. Re-observe before you rely on the effect.
- `focus.preserved` is `false` when the frontmost app, its focused window, or its focused element changed during the action. `focus.guardRestored: true` means the target took focus and the focus guard put the user's app back. In that case `preserved` is `false` but the user's app is in front again. If `preserved` is `false` without `guardRestored`, focus moved and stayed moved. Tell the user and do not switch apps yourself. `focus.cursorMoved` is `true` only after a `--foreground` action.
- `presence` is `active` when the lease, the wait for the user, and the focus guard ran. `unavailable` means the presence process could not be reached and the input went out without a cursor, lease, guard, or wait. Run `doctor` to see why. `disabled` means `SCREENCOMMANDER_PRESENCE=0`. `--foreground` actions report `active` too: they draw no cursor and begin no focus guard, but they lease their app, wait for the user, and stop for the abort key.
- `menuItem` on a `key` result names the menu item it pressed. No `menuItem` means the chord went out as key events.
- `keyWindowID` on `type`, `key`, and `keys` is the window the keys went to, when that is known. Check it when the app has several windows.
- `axError` on a `click` means the app gave no answer to the accessibility press, for example `cannotComplete`. The press may have run, so screencommander did not click again. Re-observe before you retry, or you may press twice.
- A bare coordinate click goes to whatever is topmost at the point. On the menu bar, a Stage Manager thumbnail, or an open menu it fails with `background_delivery_unavailable`. Pick a menu item with `click --element` instead.
- Action commands also capture the main display before and after and compare the two. A background or covered window is not visible in those shots, so confirm with `state`. `--no-postshot` skips both captures. A `postshotError` in the result means the capture failed and the action still ran, so do not repeat the action.

## When something goes wrong

| Error (exit) | Meaning | Next move |
|---|---|---|
| `background_delivery_unavailable` (51) | No background path for this input. The message says why: the app's profile is `unsupported`, the window is not on screen, a Command chord has no menu item and no window to make key, a system key or shortcut alias, or missing private symbols. | Act on an element instead if one exists. Otherwise tell the user what failed, and use `--foreground` only if the task needs it and the user agrees. |
| `target_busy` (52) | Another agent session holds the lease on this app. | Wait and retry in the background, or work in another app. A lease ends once its session has left the app alone for 15 seconds. Pass the other `--session` name only if that session is your own. |
| `aborted_by_user` (53) | The user pressed Control-Option-Command-Period. All agent input is stopped. | Stop and tell the user. Never retry with `--foreground` and never run `resume`. Only the user resumes. |
| `user_interrupted` (54) | The user kept using the target app for about 5 seconds, or for a `--foreground` action kept using the keyboard or mouse anywhere, and the action was not delivered. | Wait until the user is done, re-read `state`, then retry in the background. Never retry with `--foreground`. |
| `element_not_actionable` (72) | The element is disabled, does not list the action, a forced `--via` tier cannot do it, or `--strict` refused a fallback. | Read the message. Re-read `state`, wait for the control to enable, use an action from its `actions`, or drop `--via` and `--strict`. |
| `element_not_found` (70) | No element matches the id or label. | Re-read `state` and use a fresh id or a better label. |
| `element_ambiguous` (82) | The label matched several elements. The message lists them. | Use `--element-id` or add `--role`. |
| `ax_tree_unavailable` (71) | The app exposes no usable tree yet. | If it is launching, wait with `observe` or retry `state`. If it stays empty, work from the window capture with coordinates. |
| `window_minimized` (84) | A minimized window could not be captured. | Read it with `elements --app <name> --all-windows` and act by element id, or ask the user to restore it. |
| `capture_timeout` (22) | A capture did not finish in time. | Retry once. If it repeats, run `doctor` and tell the user. |
| `stale_metadata` (83) | The capture no longer matches the screen. | Capture again with `state` or `screenshot --window`. |
| `app_not_found` (81) / `window_not_found` (80) | No running app or window matches. | Use `apps` or `windows`. Start a missing app with `launch --app <name>`. |
| `observe_timeout` (73) | The `--until` condition never held. | Re-read `state` and decide again. |
| `permission_denied_screen_recording` (10), `permission_denied_accessibility` (11) | A permission is missing. | Run `doctor`, give the user the printed System Settings path, and wait. |

## Per-app expectations

`doctor --app <name>` classifies an app from its bundle and sends no input. It reports a support level, the tier order for mouse and keyboard input, and a `reason`.

- `supported`: native AppKit and SwiftUI apps. Accessibility actions and window events work while the app is in the background.
- `degraded`: some input is ignored while the app is inactive, and `reason` says which. Chromium and Electron apps take mouse and key events only through `focusAssisted`, and `type` sends them key events first. Catalyst apps have some controls that react only while the app is active. Qt and Java apps have sparse trees and need a key window. In practice, prefer element actions, re-observe after every action, and expect some `verified: "unknown"` results where nothing changed.
- `unsupported`: game engines. Coordinate and keyboard input is refused with `background_delivery_unavailable`. Accessibility actions on elements are still tried.

Window-addressed input reaches only a window's active tab or web view. Switch tabs before you act on another one. Chrome activates itself for menu commands that open a window or tab, and the result then shows `guardRestored: true`.

## Sessions and the agent cursor

Every action runs in a session that leases the target app. The CLI uses `--session <name>`, then `SCREENCOMMANDER_SESSION`, then `default`. A lease ends once the session has not acted on the app for 15 seconds, whether it came from a one-shot command or from `serve`. One-shot commands keep their app between calls inside that window, and `serve` loses all its leases when it exits. When more than one agent drives this Mac, give each its own session name with `SCREENCOMMANDER_SESSION=<name>`. A second session that touches a leased app gets `target_busy`. Each session draws its own cursor color.

The agent cursor shows the user where you are acting. It glides to the target before each pointer action, `select-text`, and `action`, and the action waits for the glide. Pass `--no-agent-cursor` when the user asks for no cursor, or for long runs of actions where speed matters. Leases, the focus guard, and the wait for the user still apply without it.

While a session is active, screencommander keeps the display awake so the screen saver does not start mid-run.

## MCP server

`screencommander serve --mcp` runs one warm process that speaks MCP over stdio and returns captures as images. Tool names follow the commands: `screenshot`, `click`, `type`, `key`, `keys`, `scroll`, `drag`, `move`, `elements`, `windows`, `focus`, `doctor`, and `cleanup` keep their names. `app_state` is `state`, `select_text` is `select-text`, `perform_action` is `action`, `list_apps` is `apps`, `launch_app` is `launch`, and `observe_wait` is `observe`. There is no `sequence` tool and no `resume` tool.

- Arguments are camelCase: `app`, `windowId`, `elementId`, `foreground`, `session`, `agentCursor`. Leave `foreground` unset.
- Results are the same envelopes as `--json`, in `structuredContent`, with the same fields and error codes. Everything in [Reading a result](#reading-a-result) and [When something goes wrong](#when-something-goes-wrong) applies.
- Start with `app_state`. The first call for a window returns the whole tree. Later calls return only changed records plus `removedIds`. Pass `full: true` to get the whole tree again.
- Action tools accept `postObserve: {"app": "<name>"}`, which adds an `observation` tree delta to the result so you can skip a separate read.
- `observe_wait` takes `app`, `timeoutMs`, and `until`, and returns the events and the outcome in one call.
- Requests run in parallel. To order one after another, set `params.dependsOn` to the earlier request id.
- Each server is its own session unless `SCREENCOMMANDER_SESSION` is set.

## Known limits

- With Stage Manager on, a window in another stage is a thumbnail. Its capture is the thumbnail and coordinate actions fail. Act on its elements.
- Minimized windows, hidden apps' windows, and windows on another Space can be captured but not clicked by coordinates. Act on their elements.
- Key-event typing goes through the Mac's text settings, such as "Add period with double-space". Line breaks go out as Return and tabs as Tab. Accessibility writes insert the text exactly.
- A running screen saver is not dismissed and a locked screen is not unlocked. If actions start failing on a locked Mac, tell the user.
- Secure text fields are never read back, so `type` into them reports `verified: "unknown"`.
