# screencommander

<img width="900" height="525" alt="image" src="https://github.com/user-attachments/assets/ea6eccab-5db4-4df1-b8e3-741914167e2d" />

`screencommander` is a command-line tool and MCP server for macOS 14 and later that lets an agent read the screen and operate apps from a terminal. It reads an app's accessibility tree as structured data or plain text, captures displays and single windows, and sends clicks, scrolls, drags, hovers, typing, and key chords.

By default, input goes to the target app in the background. screencommander does not activate the app and does not move your cursor, so you can keep working while an agent runs. An agent cursor, drawn just above the target window, shows where the agent is acting. Pass `--foreground` to post input through the HID event tap instead, which moves the real cursor and can bring the target app forward.

- **Read.** `elements` and `state` return the accessibility tree as records or indented text, so a model without vision can work from text alone. `observe` streams UI changes as they happen.
- **Capture.** `screenshot` captures a display or one window, including covered, minimized, and hidden windows. Every capture writes metadata that maps image pixels to screen points.
- **Act.** Element actions resolve their target fresh from the accessibility tree. Coordinate actions map pixels, points, or normalized values through the capture metadata. Every result says which delivery tier ran, whether focus stayed where it was, and, where the tool can check, whether the action took effect.
- **Serve.** `serve --mcp` exposes the same commands as MCP tools and returns screenshots inside the response.

`SKILL.md` is the operator runbook: the command patterns an agent needs, in the order it needs them.

## Requirements

- macOS 14.0 or later
- Xcode Command Line Tools with Swift 5.10 or later

## Install

screencommander is built from source. The binary is not signed with a Developer ID and is not notarized.

```bash
scripts/install.sh --prefix "$HOME/.local"   # user-local install, no sudo
scripts/install.sh                            # installs to /usr/local/bin, asks for sudo when needed
```

The script runs `swift build -c release` and copies the binary to `<prefix>/bin/screencommander`. `--skip-build` installs the release build that is already there. For a user-local install, put `~/.local/bin` on your `PATH`.

To try it without installing, run `swift run screencommander --help` from the repository.

## Permissions

screencommander needs two macOS privacy permissions. macOS grants them to the app that starts screencommander, usually your terminal app or the app that runs your MCP client, not to the screencommander binary. Grant them under System Settings > Privacy & Security.

| Permission | Needed by | Settings link |
|------------|-----------|---------------|
| Screen Recording | `screenshot`, `state`, `windows`, and the before and after captures that input commands take | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Accessibility | `click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `elements`, `state`, `select-text`, `action`, `observe` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |

A command that lacks a permission fails right away with exit `10` or `11` and a message that says where to grant it. Without Screen Recording, input commands still deliver their input and print a warning in place of the before and after captures.

The presence process that draws the agent cursor runs from the same binary and uses the same grants. Its listen-only input tap needs Accessibility or Input Monitoring.

`screencommander doctor` shows where you stand:

- each permission, granted or denied, with the Settings link when it is denied
- the active displays, with their IDs and bounds in points
- every private symbol the background tiers use, whether it resolved, and what uses it
- the presence process: its pid, whether its input tap works, whether the abort key has stopped agent input, whether it is keeping the display awake, and each session with its leased pids and cursor state. When presence is not running, `doctor` says whether it is turned off, why it failed to start, or that it will start on the next background action.

`doctor` exits `0` even when a permission is missing, and it never starts the presence process. `doctor --app <name|pid|bundle ID|path>` adds that app's delivery profile (see [Per-app delivery profiles](#per-app-delivery-profiles)).

## First run

Open TextEdit with a blank document, then read before you act:

```bash
screencommander state --app TextEdit --text
```

`state` captures TextEdit's front window without activating it and prints its accessibility tree as indented text. The capture also becomes the coordinate reference for later coordinate actions.

```bash
screencommander type "Hello from an agent" --app TextEdit
screencommander key "cmd+a" --app TextEdit
screencommander elements --app TextEdit --text
```

`type` writes into TextEdit's focused text view through accessibility. `key` finds Select All in TextEdit's menus and presses it, and the output names the menu item. Neither command brings TextEdit forward. `elements` reads the tree again so you can check the result.

To act on pixels instead, capture first and click at a point in that image:

```bash
screencommander screenshot --window TextEdit
screencommander click 400 300
```

The click is addressed to the captured window, at the same place in the image. Add `--json` to any command for one machine-readable result object.

## Upgrading from 0.5.0

Several defaults changed in ways that break 0.5.0 scripts.

- **Input goes to the background.** `click`, `scroll`, `drag`, `move`, `type`, `key`, and `keys` post to the target app without activating it and without moving the cursor. In 0.5.0, keyboard commands typed into the frontmost app through the HID event tap, and coordinate clicks could activate their target first. Pass `--foreground` for the 0.5.0 behavior.
- **`--no-cursor` does nothing.** `click` and `scroll` still accept it, and so do the MCP `noCursor` field and `sequence` steps, so old scripts keep running. It is hidden from help.
- **`type` inserts at the caret.** Its accessibility write used to replace an element's whole value. Use `--replace` for that now.
- **`type` no longer uses the clipboard by default.** The default `--mode` was `paste` and is now `unicode`, in the CLI, MCP, and `sequence` steps. `type` tries accessibility first, then Unicode key events. The clipboard is used only with `--mode paste`, and only when `--foreground` delivery runs. See [Type](#type).
- **The `pid` tier is now `window`.** `--via pid` still works as an alias, but results report `deliveryMethod: "window"`.
- **System-wide keys need `--foreground`.** Without it, `key` and `keys` refuse media and system keys, the `spotlight`, `raycast`, and `missioncontrol` aliases, and the system-wide chords listed in [Shortcuts and system keys](#shortcuts-and-system-keys), such as `cmd+tab` and `cmd+space`, with exit `51`.
- **Keys without a target follow the last window screenshot.** After `screenshot --window` or `state`, `type`, `key`, and `keys` with no `--app` or `--window-id` go to that window, the same window an untargeted click goes to. In 0.5.0 they went to the frontmost app. See [Choosing the target](#choosing-the-target).
- **`click --prime` does nothing.** A click always sends a pointer move first, so the flag had no job left. `click` still accepts it, and so do `sequence` steps, so old scripts keep running. It is hidden from help, and the MCP `click` tool no longer lists `prime`.
- **`sequence` files are checked.** A key a step does not take fails the whole file with `invalid_arguments`, naming the step and the key, before any step runs. Field names now match the MCP tools (`durationMs`, `dwellMs`, `delayMs`, `timeoutMs`). The 0.5.0 spellings `durationMS`, `dwellMS`, `delayMS`, and `timeoutMS` still work. Numbers outside their allowed range fail with `invalid_arguments` too.
- **Parse errors are JSON when JSON is asked for.** With `--json`, `--output json`, or `SCREENCOMMANDER_OUTPUT=json`, an unknown option or a missing argument prints the error envelope with code `invalid_arguments` and exits `60`, instead of usage text.
- **New exit codes:** `22` (`capture_timeout`), `51` (`background_delivery_unavailable`), `52` (`target_busy`), `53` (`aborted_by_user`), `54` (`user_interrupted`), and `84` (`window_minimized`).
- **A helper process starts on demand.** The first background action starts the presence process, which draws the agent cursor and holds session leases. Set `SCREENCOMMANDER_PRESENCE=0` to turn it off.
- **Results carry more fields.** Input actions now report `focus`, `verified`, and `presence`. See [Action results](#action-results).

## How input is delivered

### Choosing the target

- Coordinate actions (`click`, `scroll`, `drag`, `move`) go to `--window-id` when it is given. Otherwise they go to the window in the screenshot metadata when that capture was a window capture. With `--app`, they go to that app's topmost window under the point at any layer, so its panels count, then to its front window. A named target gets the input even when another app's window, the Dock, or the menu bar covers the point. A drag is addressed to the window under its start point.
- With no target named (bare coordinates from a display screenshot), the input goes to whatever is topmost at the point at any layer: a panel, the Dock, a status item, the desktop, or a document window. It never goes to a window underneath the topmost one. When the topmost thing cannot take background input, the action fails with `background_delivery_unavailable`, names what is there, and says `--foreground` reaches it. That happens for the menu bar (the window server draws it), a Stage Manager thumbnail, and an open pop-up or context menu, since a menu takes its choice only from the real pointer and a posted click just closes it. Choose a menu item with `click --element` instead.
- Element actions go to the element's app: `--app`, else the owner of `--window-id`, else the frontmost app. `--element` searches the app's focused window, or `--window-id` when it is given. An `--element-id` outside `--window-id` fails with `invalid_arguments`. Event tiers address the window that holds the element, not whichever window is topmost at its center. When another window of the same app covers the element's center, the event tiers refuse with `background_delivery_unavailable` rather than click through it, and `ax` still works.
- Keyboard actions (`type`, `key`, `keys`) go to the owner of `--window-id`, else `--app`, else the window in the screenshot metadata when that capture was a window capture and the window still exists, else the frontmost app. That window counts as if `--window-id` named it, so after `state --app TextEdit`, a bare `type` goes to TextEdit and not to the terminal you typed it in. A display screenshot clears it. `--foreground` keys with no target skip it and go to the frontmost app, as before. Element actions do not use it. The events are posted to that one process. Inside the app, keys go to its key window. A window named with `--window-id`, or the window that holds a target element, must get the keys: delivery makes it key first without activating the app (the `focusAssisted` tier, also when the app is frontmost), checks through accessibility that it became key, and fails with `background_delivery_unavailable` rather than typing into another window. The plain `window` tier cannot change the key window, so it runs only when the named window is already key. Results report `keyWindowID`, the window the keys went to, when that is known.
- A window that is not on screen (minimized, its app hidden, on another Space, or shown only as a Stage Manager thumbnail) gets no mouse events. A coordinate action addressed to one, through `--window-id` or the screenshot metadata, fails with `background_delivery_unavailable` instead of clicking whatever is on screen at that point now. Element actions on such a window use the `ax` tier only. Keys still go to the app's process.
- With Stage Manager on, the windows of other stages show as thumbnails. screencommander compares each window's reported bounds with its real frame and treats a thumbnail as not on screen for mouse events. Keys still reach it, and its window can still be made key.

### Delivery tiers

Each action tries tiers in order and reports the one that worked as `deliveryMethod`.

| Tier | What it does | When it is used |
|------|--------------|-----------------|
| `ax` | Runs an accessibility action or attribute write on the element: `AXPress`, `AXShowMenu`, an `AXSelectedText` or `AXValue` write, or a page-scroll action. | Element `click`, `type`, and `scroll --direction`, and `type` into the target app's focused text field. Double and triple clicks, modifiers, and middle clicks cannot be expressed this way and fall through. |
| `window` | Posts events to the target process with `CGEventPostToPid`. Mouse events carry the target window ID, the pid, and a window-local location. | The first event tier for native, Catalyst, and unclassified apps, and the fallback for Qt and Java apps. Keyboard events do not need a window. |
| `focusAssisted` | Sends a focus-without-raise record to the target window, makes it key with one click addressed to a point outside its frame, sends the same events as `window`, then tells the target it lost focus. The frontmost app does not change and receives nothing. When the app's profile asks for it, keyboard events go through `SLEventPostToPid` with an authentication message. | The only event tier for Chromium and Electron apps, the first for Qt and Java apps, and the fallback for the rest. Also the tier for background Command shortcuts. Needs an on-screen window. |
| `global` | Posts to the HID event tap, so the real cursor moves and keys reach the frontmost app. Coordinate clicks with a known target, and keyboard actions given `--app`, `--window-id`, or an element, activate the target first. Scrolls, drags, moves, and element clicks activate nothing. | Only with `--foreground`. |

- A downgrade to a later tier is recorded in the result, not raised. `--strict` runs only the first tier, so a failure there is returned instead of falling through.
- `--via ax|window|focusAssisted|global` forces one tier with no fallback. `pid` is an alias for `window`. `--via global` requires `--foreground`. `--via ax` requires an element, except that `type` also accepts a focused text field and `scroll` also requires `--direction`. `--via window` or `--via focusAssisted` can force a tier the app's profile leaves out, and fails with `background_delivery_unavailable` when the tier cannot run for this target.
- Without `--foreground`, an action with no usable tier fails with `background_delivery_unavailable` (exit `51`). The message gives the reason: the app's profile is `unsupported`, the target has no on-screen window for mouse events, or the private symbols the tier needs are missing.
- With `--foreground`, coordinate actions, `key`, and `keys` go straight to `global`. `type` still tries the `ax` tier first. Element actions keep the ladder and add `global` at the end. `--foreground` actions draw no agent cursor and begin no focus guard, but they stop for the abort key, lease their target app when they have one, and wait for the user to go quiet (see below).
- Synthesized events come from a private event source with their flags set explicitly, so modifier keys the user is holding do not leak into them.

### Shortcuts and system keys

- Command shortcuts work on background apps through `key`. AppKit and Chromium route menu commands and a window's own shortcuts through the key window, so `key` first looks the chord up in the target app's menu bar. If it is a menu item, `key` makes the window key and presses the item through accessibility, which runs the command without opening the menu, and the result's `menuItem` names it. An item that reads disabled gets the chord as key events so the app can re-check it, and still disabled fails with exit `72`. A chord that is not a menu item goes out as key events in the key window.
- A Command chord that matches no menu item and cannot reach a key window fails with `background_delivery_unavailable`. That happens when the app has no on-screen window or the focus-record symbols are missing. An enabled menu item can still be pressed through `ax` without a key window.
- `keys` does not look up menu items. A sequence that holds Command needs a key window, so it uses `focusAssisted` alone and fails with `background_delivery_unavailable` when the target has no on-screen window. Send a single shortcut such as `cmd+s` with `key`.
- Media and system keys (`volumeup`, `volumedown`, `mute`, `brightnessup`, `brightnessdown`, `launchpad`, `play`, `next`, `prev`) have no target app. Without `--foreground`, `key` and `keys` refuse them.
- `spotlight` and `raycast` are aliases for `cmd+space`, and `missioncontrol` is an alias for `f3`. Without `--foreground`, `key` and `keys` refuse them.
- macOS handles a few chords itself before any app sees them. Sent to an app in the background they would arrive as plain keys and do nothing, so without `--foreground` `key` and `keys` refuse them with exit `51`. The list is `cmd+tab`, `cmd+shift+tab`, `cmd+space`, `cmd+option+space`, `cmd+option+esc`, `cmd+ctrl+q`, `cmd+shift+q`, `cmd+shift+3`, `cmd+shift+4`, `cmd+shift+5`, `cmd+shift+ctrl+3`, and `cmd+shift+ctrl+4`. `keys` counts modifiers held by earlier `down:` steps. Every other chord goes to the target app, including ones an app may handle itself such as `f3`, `ctrl+left`, and `cmd+h`.

### Per-app delivery profiles

Every action classifies its target app by reading the app bundle and picks a tier order from the result. `doctor --app <name|pid|bundle ID|path>` shows the profile for one app and sends it no input: toolkit, support level, the reason, the mouse and keyboard tier order, and the bundle evidence. Classifications are cached under `<state dir>/profiles/`, keyed by bundle ID and version.

| Toolkit | Support | Event tiers, in order |
|---------|---------|-----------------------|
| `native` (AppKit or SwiftUI) | `supported` | `window`, `focusAssisted` |
| `chromium` (Chrome-family browsers and CEF apps) | `degraded` | `focusAssisted` |
| `electron` | `degraded` | `focusAssisted` |
| `qt`, `java` | `degraded` | `focusAssisted`, `window` |
| `catalyst`, `unknown` (no app bundle) | `degraded` | `window`, `focusAssisted` |
| `gameEngine` (Unity, Unreal, or Godot) | `unsupported` | none |

- `ax` comes first for element actions in every profile.
- `supported` means accessibility actions and window-addressed events were verified live for that toolkit. `degraded` means some input works in the background and some does not, or it was not verified, and the profile's `reason` says which. `unsupported` means background coordinate and keyboard input is refused unless `--via` forces a tier or `--foreground` is set.
- Chromium and Electron windows drop plain `window` clicks while they are not key, so `window` is never their fallback. `--via window` still forces it. On macOS 15 and later, their keyboard events in `focusAssisted` go through `SLEventPostToPid` with an authentication message when those symbols resolve.
- When `CGEventSetWindowLocation` is missing, every app drops to `degraded` and loses its mouse event tiers. When the focus-record symbols are missing, `focusAssisted` drops out, which leaves Chromium and Electron apps with accessibility actions only.

### Private APIs

The `window` and `focusAssisted` tiers depend on private functions: `CGEventSetWindowLocation`, `SLEventPostToPid`, `SLEventSetAuthenticationMessage`, `SLSEventAuthenticationMessage`, `SLPSPostEventRecordTo`, `_SLPSGetFrontProcess`, and `GetProcessForPID`. The frontmost app comes from `_SLPSGetFrontProcess` and `GetProcessPID`. `elements --window-id` uses `_AXUIElementGetWindow`, captures of windows that are not on screen use `SLSHWCaptureWindowList`, and `SLSGetWindowBounds` tells a Stage Manager thumbnail from a window on screen.

screencommander resolves each one at runtime with `dlsym` and does not link against any of them. When one is missing, the tier that needs it is skipped. `doctor` lists every symbol, whether it resolved, and what uses it. Any macOS update can change or remove these functions.

## Agent cursor and presence

Background actions go through a presence process. It is the same binary running a hidden `presence` subcommand. The first background action starts it, from the CLI or from `serve`, and it exits after 120 seconds with no session, no focus guard, and no abort in force. A client that stays connected, such as `serve`, does not keep it running. It has no Dock icon and never becomes the frontmost app.

**Agent cursor.** A small click-through window drawn just above the target window. It glides to the target point before mouse actions, `select-text`, and `action`, and plays a press for clicks. Keyboard actions do not move it. Each session gets its own color. It follows its window when the window moves, fades out while that window is minimized, hidden, or on another Space, and comes back with it. It does not glide to an element whose window is not on screen. After an action succeeds it shows a loading state while the agent decides its next step, and it shows a paused state while an action waits for the user. Ten seconds after the session's last action it fades out, and the next pointer action brings it back. `SCREENCOMMANDER_CURSOR_LINGER_MS` changes that delay. `--no-agent-cursor` (MCP and `sequence`: `agentCursor: false`) or `SCREENCOMMANDER_AGENT_CURSOR=0` turns it off. Leases, the focus guard, and yielding still apply without it.

**Sessions and leases.** Each action leases its target app for one session, `--foreground` actions included. Another session that tries to drive the same app fails with `target_busy` (exit `52`). A lease ends once its session has not acted on that app for 15 seconds, and `SCREENCOMMANDER_LEASE_IDLE_MS` changes the period. The rule is the same for one-shot CLI commands and for `serve`. A CLI lease outlives the command that took it, so a run of commands keeps its app, while every lease `serve` holds ends the moment `serve` exits, is killed, or its input closes. A session ends when it holds no lease, and its cursor goes with it. The session ID comes from `--session`, then `SCREENCOMMANDER_SESSION`, then `serve-<pid>` inside `serve`, then `default`. Inside `serve`, input to the same app is also serialized, and every `--foreground` action waits for any other one, because they all share the system's input stream. Parallel tool calls never interleave events.

**Focus guard.** For 3 seconds after each background action, and 5 seconds around `launch`, presence undoes the target activating itself. It puts back the app the target took focus from, which is the app the user was in at that moment. Each action samples the frontmost app again, so the guard never brings back an app the user has since left. When in doubt it does nothing. Any real input in the 1.5 seconds before the activation counts as the user's doing: a key, a modifier such as a held Command-Tab, a click, pointer motion, a scroll, or a trackpad swipe or other gesture. So does a change of Space. It restores at most three times per action. `focus` and `--foreground` end the guard on their target before activating it, so the guard never undoes an activation you asked for.

**Yielding to the user.** A listen-only event tap watches real input: keys, modifiers, clicks, pointer motion, scrolls, and gestures. Presence records which app each key press, click, scroll, or gesture went to, whether or not any session has leased that app. An action waits for one quiet second when the user worked in its target app within the last second, even if this is the session's first action there, or in any app the session has leased. A `--foreground` action waits for one quiet second after any real input at all, because the user's keys and mouse share the system's input stream with it. The wait checks at most once per second. After 5 seconds of continued user activity the action fails with `user_interrupted` (exit `54`) and nothing is delivered. Events that screencommander posts never count as the user's: every process that posts events talks to presence first, which tells presence its pid.

**Abort key.** Control-Option-Command-Period stops every session. Every input action, `--foreground` ones included, `launch`, and `focus` then fail with `aborted_by_user` (exit `53`) until someone runs `screencommander resume`. The stop lives only in the presence process, so that process stays running while input is stopped. There is no MCP tool for `resume`, so an MCP client cannot undo the user's stop.

Yielding and the abort key need the input tap. When the tap cannot start, both are off and `doctor` says so.

**Keeping the display awake.** While any session is active, presence holds a display-awake power assertion named "screencommander: an agent session is active", so the display does not sleep and the screen saver does not start in the middle of a run. It releases the assertion when the last session ends and when presence exits, so a `serve` left running does not keep the Mac awake once its leases go idle. It never wakes a sleeping display, dismisses a running screen saver, or touches a locked screen. `SCREENCOMMANDER_KEEP_AWAKE=0` turns it off. With presence turned off, `serve` holds the same assertion itself for two minutes after each tool call. `doctor` shows whether the assertion is held, and `pmset -g assertions` lists it.

**When presence is missing or off.** If the presence process cannot be reached, actions still run and report `presence: "unavailable"`. `SCREENCOMMANDER_PRESENCE=0` turns presence off entirely: no cursor, leases, focus guard, or yielding, and actions report `presence: "disabled"`.

**Socket.** Presence listens on a Unix socket at `presence.sock` in the state directory. A socket path can hold at most 103 bytes. When the state directory makes the path longer, every process uses `/tmp/screencommander-<uid>/presence-<hash>.sock` instead, where the hash comes from the state directory path. That directory must belong to the current user and allow no group or other access, or presence refuses to start and `doctor` reports why. When presence fails to start, the reason is saved to `presence-start-error.txt` in the state directory and shown by `doctor`.

Display captures from `screenshot`, before and after captures, and frame diffs leave out the agent cursor. Window captures never include it, since it is a separate window.

## Action results

Every input action's JSON result reports what happened. The full shapes are in [docs/json-output-schema.md](docs/json-output-schema.md).

- `deliveryMethod` is the tier that delivered the input. For `type`, `inputMode` says what put the text in: `"unicode"` key events, a `"paste"`, or an `"ax"` accessibility write, whatever `--mode` asked for.
- `verified` is `true`, `false`, or `"unknown"`. `"unknown"` means the events were posted and nothing confirmed that the app handled them. Check with the frame diff or by reading `elements` again. These actions read state back:
  - `type` through `ax` reports `true` when the value equals the expected text and `false` when it does not. `type` into an element with key events reports `true` when the value changed to the expected text, or holds the text where the caret was, and `"unknown"` otherwise. Text that was already in the field does not count. `type` with key events and no element reports `"unknown"`. Secure text fields are never read and report `"unknown"`.
  - Page scrolls compare the scroll bar position before and after, when accessibility exposes one.
  - `select-text` reads the selection back.
  - `key` reports `true` for a menu item it pressed in a key window.
- `focus` is `{ preserved, frontmostBefore, frontmostAfter, focusedWindowBefore, focusedWindowAfter, focusedElementBefore, focusedElementAfter, cursorMoved, guardRestored }`, sampled before delivery and again about 60 ms after. The window and element fields identify the frontmost app's focused window and element through accessibility, never their titles or values. `preserved` is false when the frontmost app, its focused window, or its focused element changed. Mouse movement never makes it false. `cursorMoved` is true only when the action moved the hardware cursor, which only `global` delivery can do, so in the background it is always false even if the user moves the mouse.
- `guardRestored` is true when the target took focus during the action and the focus guard put the previous app back before the after-sample. `preserved` is then false although the frontmost app ends up unchanged. The field is absent when presence did not take part, or when the running presence process is an older build that does not report restores.
- `presence` is `active`, `unavailable`, or `disabled`.

## Support and known limitations

### Tested configurations

Live tests ran on two Apple silicon Macs, each with a single display: one on macOS 15 and one on macOS 27.2 with Stage Manager on.

| App toolkit | macOS 15 | macOS 27.2 |
|-------------|----------|------------|
| AppKit (a test app) | Verified: `ax` and `window` for `click`, `type`, `key`, `keys`, `scroll`, `move`, and `drag`, `focusAssisted` for `click`, `type`, and `scroll`, Command shortcuts, `--foreground` and paste mode, the agent cursor, leases, the focus guard, yielding, the abort key, and captures of minimized, hidden, other-Space, and full-screen windows. | Verified: the same, plus `focusAssisted` for `key` and `keys`, `type` cases (mid-string caret, selection, `--replace`, non-ASCII text, 3,000 characters), `select-text`, `action`, `state`, `serve`, `sequence`, and `observe`. `--foreground` was checked on Calculator. |
| Electron (a test app on Electron 42) | Partly verified: clicks, typing through each key tier, keys, Command shortcuts, scrolling, `state`, and window capture. The accessibility text input and key-events-first ordering came later and were not tested here. | Verified: clicks, typing into inputs, text areas, and contenteditables, keys, menu shortcuts, scrolling, `state`, and window capture. |
| Google Chrome 154 | Not tested. | Verified in a separate instance with its own profile: clicks, typing, keys and menu shortcuts, scrolling, `select-text`, `state`, `elements`, and window capture. |
| Other Chromium browsers, CEF apps | Not tested. | Not tested. |
| Catalyst, Qt, Java | Not tested. | Not tested. |

On macOS 27.2, every background action left the frontmost app and the front-to-back window order unchanged, apart from the Chrome case below. Multi-display setups, macOS 26, and Intel Macs have not been tested.

### Known limitations

- In a Chromium or Electron window, input reaches only the active tab or web view.
- Typing through key events passes through the Mac's text settings. With "Add period with double-space" on, two spaces become a period and a space. Accessibility writes insert the text exactly.
- Chrome brings itself forward when a shortcut opens a new window or tab, such as `cmd+n` or `cmd+t`. The focus guard puts the previous app back, and the result reports `guardRestored: true`.
- Stage Manager thumbnails are refused for mouse input. Act on an element instead, or bring the stage forward.
- A screen saver that is already running is not dismissed. Operating a locked screen is not supported.
- On macOS 15, one test saw a coordinate click into Chromium web content move the window toward the front. It did not happen on macOS 27.2 with any tier, and it was never reproduced.

## Commands

### Options shared by input commands

Targeting and presence:

- `--app <name|pid>` picks the target app. `--window-id <id>` addresses events to one window (IDs come from `windows`). For keys, that window is made key first. For `--element`, the search runs in that window. With neither, coordinates and keys go to the window of the last window screenshot (see [Choosing the target](#choosing-the-target)).
- `--foreground` allows activation and `global` delivery.
- `--session <id>` names the agent session that leases the target. `--no-agent-cursor` skips the agent cursor for this action.
- `click`, `scroll`, `drag`, `move`, `type`, `key`, and `keys` take all of these. `select-text` and `action` take all but `--foreground`, and their `--window-id` picks the window `--element` searches and the agent cursor glides over.
- `click`, `scroll`, and `type` also take `--via` and `--strict` (see [Delivery tiers](#delivery-tiers)).

Coordinates (`click`, `scroll`, `drag`, `move`):

- Coordinates are in the space of the last capture. `--space pixels|points|normalized` picks the unit (default `pixels`), and `--meta <path>` picks the capture metadata (default `~/Library/Caches/screencommander/last-screenshot.json`). A capture of one window maps against that window's bounds.
- Results include an advisory `metadataFreshness`. `--strict-metadata` fails with `stale_metadata` (exit `83`) before any input is sent when the metadata no longer matches the live display or window.

Before and after captures (`click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `sequence`):

- Each action captures the main display before and after, prints both paths, and reports the changed region when pixels differ.
- A capture never holds up or fails the action. Each one gives up after at most 11 seconds, even when ScreenCaptureKit never answers. A capture that fails or times out prints a warning, and the JSON result reports the action with `preshotError` or `postshotError` (`{ code, message }`) in place of the missing capture.
- `--no-postshot` skips both captures. `--no-diff` keeps the captures and skips the comparison. `--diff-grid <1...512>` (default `64`) and `--diff-threshold <0...1>` (default `0.04`) tune the comparison.
- MCP action tools take no before and after captures.

### Doctor

```bash
screencommander doctor
screencommander doctor --json
screencommander doctor --app Safari
```

See [Permissions](#permissions) for what it reports and [Per-app delivery profiles](#per-app-delivery-profiles) for `--app`.

### Screenshot

```bash
screencommander screenshot
screencommander screenshot --display main --out ./desk.png --format png --meta ./desk.json --cursor
screencommander screenshot --window 12345
screencommander screenshot --window Safari
```

- Captures with ScreenCaptureKit. `--display` takes a display ID or `main` (the default). `--format` is `png` (default) or `jpeg`. `--cursor` includes the hardware cursor.
- The image goes to `~/Library/Caches/screencommander/captures/Screenshot-<timestamp>-<id>.<ext>` unless `--out` says otherwise, and the metadata to the same path with `.json` unless `--meta` says otherwise. Every capture also updates `~/Library/Caches/screencommander/last-screenshot.json`, which coordinate actions read by default.
- `--window` takes a window ID or an app-name prefix, which captures that app's frontmost window. Covered windows work. The metadata gains `windowID` and `windowBoundsPoints`, and coordinate actions that follow are addressed to that window.
- ScreenCaptureKit cannot capture a window that is not on screen: minimized, its app hidden, or on another Space, including a full-screen Space. Those windows are captured from the window server's own copy instead (`SLSHWCaptureWindowList`), which returns the full window. If that copy is unavailable, the command fails at once, with exit `84` (`window_minimized`) for a minimized window and exit `20` (`capture_failed`) for the others. A Stage Manager thumbnail captures as the thumbnail.
- Any capture that takes longer than 5 seconds fails with exit `22` (`capture_timeout`).
- PNG and JPEG files carry the display's color profile, so color-managed viewers show the colors that were on screen.
- Captures are never pruned automatically. Use `cleanup`.

### Click

```bash
screencommander click 640 320
screencommander click 0.25 0.25 --space normalized --meta ./desk.json --button right --double
screencommander click 640 320 --modifiers cmd,shift
screencommander click --element "General" --app "System Settings"
screencommander click --element-id 0.3.2 --app Safari
screencommander click --element "Save" --role button --via ax
screencommander click 640 320 --verify-target
screencommander click 640 320 --app Safari --foreground
```

- `--button left|right|middle` (default `left`), `--double`, `--triple`, and `--modifiers cmd,shift,option,ctrl`.
- `--element "<title or label substring>"` or `--element-id <id>` clicks an accessibility element instead of a point. The element is resolved fresh at click time, since IDs from `elements` are positions in the tree. No match exits `70` (`element_not_found`), and an ambiguous substring exits `82` (`element_ambiguous`). Narrow it with `--element-id`, `--role`, or `--app`.
- Element clicks try `ax` first (`AXPress` for left clicks, `AXShowMenu` for right clicks), then the event tiers at the element's center. Coordinate clicks start at the event tiers. A disabled element fails with exit `72` before any tier runs.
- Only a refusal from the app (`actionUnsupported`, `notImplemented`, and the like) moves an element click on to the event tiers. When the app answers an `AXPress` with no confirmation, such as `cannotComplete` after a timeout, the press may still have run, so screencommander does not click again. The result reports `deliveryMethod: ax` with `axError` naming the answer, and `verified` is `true` only when the element's value changed. An element that went away fails with exit `72`.
- An element click with `--foreground` that reaches `global` activates the app, raises the element's window, and checks that the element's center now hits that window and, where accessibility can tell, that element. Anything else on top fails with exit `72` and nothing is clicked.
- A click is a pointer move, then the down and up events. By default it also sends one more pointer move and waits about 90 ms first. `--raw` skips that extra move and wait. With `--foreground`, a coordinate click activates its target first when the target is known from `--app`, `--window-id`, or window metadata, unless `--raw` is set.
- `--verify-target` (coordinate clicks only) hit-tests the point through accessibility first and includes the element found there in the result.

### Scroll

```bash
screencommander scroll 640 800 --dy -5
screencommander scroll 640 800 --dy 300 --unit pixels
screencommander scroll 640 800 --dx 2
screencommander scroll --element "Content" --app Safari --dy -5
screencommander scroll --element-id 0.4 --app Safari --direction down --pages 2
```

- Posts a scroll-wheel event to the window at the point. `--unit` is `lines` (default) or `pixels`. At least one of `--dx` and `--dy` must be nonzero unless `--direction` is set.
- `--element` or `--element-id` with `--dx`/`--dy` scrolls at the element's center through the event tiers. These scrolls have no `ax` tier.
- `--direction up|down|left|right` with `--pages <1...50>` (default `1`) page-scrolls an element instead. It tries `ax` first: the element's page-scroll actions, its scroll bar's page actions, or a scroll bar value write. The event tiers then send about 90% of the element's height or width per page. `verified` compares the scroll bar position before and after when accessibility exposes one.

### Drag

```bash
screencommander drag 300 400 900 400
screencommander drag 300 400 900 400 --button right --steps 20 --duration-ms 600
```

- Maps both endpoints through the same metadata and posts mouse-down, interpolated drag events, and mouse-up to the window under the start point. The agent cursor follows the drag.
- `--steps` (1 to 10000) defaults to `12` and `--duration-ms` (0 to 60000) to `300`. There is no `--via`.

### Move

```bash
screencommander move 640 320
screencommander move 640 320 --dwell-ms 250
```

- Posts one mouse-move event to the window under the point, so the app sees a hover. `--dwell-ms` (0 to 60000) waits after the move. There is no `--via`.

### Type

```bash
screencommander type "hello world" --app TextEdit
screencommander type "user@example.com" --element "Email" --app Safari
screencommander type "hello" --element-id 0.4.1 --via ax
screencommander type "new title" --element "Title" --app Notes --replace
screencommander type "slow text" --delay-ms 50 --json
```

- `type` types. The text goes in at the field's caret and replaces whatever is selected there, the same as pressing the keys. `--replace` replaces the field's whole value instead. It needs an element or a focused text field, or it fails with exit `72`.
- Tier `ax` comes first. With `--element` or `--element-id` it writes to that element. Without one it uses the target app's focused element when that is a text field, text area, or combo box, or accepts a written `AXSelectedText` (and, with `--window-id`, sits in that window). It writes `AXSelectedText`, which inserts at the caret. Chromium and Electron accept that write and ignore it, so when the value reads back unchanged, `type` splices the text into `AXValue` and moves the caret to the end of the insert. `--replace` writes `AXValue`.
- When the field does not take the text through accessibility and its value is unchanged, `type` puts back the caret and selection the attempt moved and falls back to Unicode key events posted to the app (`window`, then `focusAssisted`, then `global` with `--foreground`). With an element, it focuses the element first and puts the caret back where it was, and the keys go to the element's own window, made key first. With `--foreground`, its window is raised and must be key before anything is typed. If the value changed but not to the expected text, because a formatter rewrote it for example, `type` stops with `verified: false` rather than typing the text a second time.
- In Chromium and Electron apps, key events come first. A write into a contenteditable fires no input event, so a page's editor would never see it, while key events reach inputs, text areas, and contenteditables as ordinary typing. With an element, `ax` runs only when no key tier can. Without an element, `ax` is not tried. `--replace` without an element selects the focused field's whole value through accessibility and then types the keys. Electron reports no focused field while its window is not key, so `type` looks for it again while delivery holds the window key. `--via ax` still forces the accessibility write.
- Key events carry one character each, including accented letters, emoji, and CJK text. `--delay-ms` (0 to 10000) waits between characters. Line breaks go out as the Return key and tabs as the Tab key, so a single-line field may treat a line break as submit, and in a web page a tab moves focus to the next field.
- `--mode unicode` is the default and never touches the clipboard. `--mode paste` uses the clipboard only when the `global` tier runs, which needs `--foreground`. The `ax` tier, and for an element the background tiers, are tried first, so add `--via global` to be sure the text is pasted. Without `--foreground`, `--mode paste` is accepted and the text goes out as key events. Paste mode saves every item on the general pasteboard with all of its types, puts the text there, sends `cmd+v`, and restores the saved items about 500 ms later, or at once when delivery fails. If another app writes to the pasteboard before the restore, the newer content stays.

### Key

```bash
screencommander key "enter"
screencommander key "tab" --app TextEdit
screencommander key "cmd+s" --app TextEdit
screencommander key "spotlight" --foreground
screencommander key "volumeup" --foreground
```

- Sends one chord in `<modifier+key>` form to the target app. Modifiers are `cmd` (`command`, `meta`), `shift`, `opt` (`option`, `alt`), `ctrl` (`control`), and `fn`.
- Media and system keys are `volumeup`, `volumedown`, `mute`, `brightnessup`, `brightnessdown`, `launchpad`, `play`, `next`, and `prev`. `spotlight` and `raycast` map to `cmd+space`, and `missioncontrol` maps to `f3`. All of these need `--foreground`.
- Command chords use the menu lookup described in [Shortcuts and system keys](#shortcuts-and-system-keys), and the result's `menuItem` names any item pressed.

### Keys

```bash
screencommander keys "down:shift" "press:right" "press:right" "up:shift" --app TextEdit
screencommander keys "press:cmd+tab" "press:cmd+tab" --foreground
screencommander keys "press:next" "sleep:100" "press:prev" --foreground
```

- Runs `down:<key>`, `up:<key>`, `press:<chord>`, and `sleep:<ms>` steps in strict order.
- For repeated shortcuts, put the modifiers in each `press` step, as in `press:cmd+tab`.
- A sequence that holds Command uses `focusAssisted` alone (see [Shortcuts and system keys](#shortcuts-and-system-keys)). A sequence with a media or system key, or a system shortcut alias such as `press:spotlight`, needs `--foreground`.

### Elements

```bash
screencommander elements                       # frontmost app, focused window
screencommander elements --app Safari --text   # text-only view
screencommander elements --app 8412 --json     # by pid
screencommander elements --app "System Settings" --roles AXButton,AXTextField --visible-only
```

- Reads the frontmost app unless `--app <name|pid>` says otherwise. An ambiguous app name reports candidate pids.
- Reads the focused window. `--all-windows` reads every window, and `--window-id <id>` reads one.
- Each element has a positional ID (a dot-joined child-index path such as `0.3.2`), role, title, value, description, enabled and focused state, supported actions, and bounds in global points.
- When `last-screenshot.json` exists, elements inside that capture also get `boundsPixels` in its pixel space, so `elements` output can drive `click <x> <y>` directly.
- `--text` prints an indented `role "title": value` view, also returned as `result.text` with `--json`.
- Limits: `--max-depth <1...200>` (default `40`), `--max-elements <1...10000>` (default `2000`, the result is marked `truncated` when hit), `--max-value-length` (default `200`), `--roles`, and `--visible-only`.
- `--profile text` skips geometry and action lookup and keeps the text and state fields. Its empty `actions` means not read, not unsupported.
- `--max-visited <1...100000>` caps visited nodes, including filtered containers. `--timeout-ms <1...60000>` sets a deadline for the read. Partial results include `visitedCount`, `truncated`, and `partialReason`.
- Chromium and Electron apps are primed for accessibility automatically (`AXManualAccessibility`, or `AXEnhancedUserInterface` as a fallback, cleared afterwards), and the result reports `axPrimed`. A freshly started one may take a moment to build its tree, so the read waits up to 3 seconds for the page content. Whether the page is there is checked against the app's own tree, so a read filtered by role or depth that never shows the web area does not wait once the page is built.
- An app with no usable accessibility tree fails with exit `71` (`ax_tree_unavailable`).

### State

```bash
screencommander state --app Safari
screencommander state --app Safari --text
screencommander state --app Safari --window-id 12345 --json
```

- Captures one window of the app and reads its accessibility tree in one call, without activating the app. `--app` is required.
- Captures `--window-id`, or the app's frontmost on-screen window. Covered windows work. When the app has nothing on screen, `state` falls back to a minimized window, or a window of the hidden app, and captures it as `screenshot --window` does. An app with no window at all fails with exit `80` (`window_not_found`). When accessibility cannot match the captured window, `state` fails with exit `71` (`ax_tree_unavailable`) rather than pair the capture with another window's tree.
- The capture becomes `last-screenshot.json`, so coordinate actions that follow map against it.
- The tree has the same shape and element IDs as `elements`, and `boundsPixels` maps into this capture. `--max-depth`, `--max-elements`, and `--text` work as they do for `elements`. `--format` is `png` or `jpeg`.
- The CLI always returns the full tree. MCP `app_state` returns a delta (see [Serve](#serve)).

### Select text

```bash
screencommander select-text --element "Body" --app TextEdit --text "hello"
screencommander select-text --element-id 0.2.1 --app TextEdit --range 0,5
```

- Selects text in an element through `AXSelectedTextRange` and reads the selection back. Pass exactly one of `--range` and `--text`.
- `--range <location>,<length>` is in UTF-16 code units. `--text` selects the first occurrence, matching case first and then ignoring it.
- Runs through the `ax` tier only. `verified` is true when the selection read back equals the requested range.

### Action

```bash
screencommander action --element-id 0.5.1 --app "System Settings" --name AXIncrement
screencommander action --element-id 0.3.2 --app Finder --name ShowMenu
```

- Performs any accessibility action the element lists in its `actions`. `--name` takes the action with or without the `AX` prefix. A name the element does not list fails with exit `72` (`element_not_actionable`), and the message lists the actions it does support.
- Runs through the `ax` tier only. `verified` is always `"unknown"`.

### Observe

```bash
screencommander observe --app TextEdit --events value
screencommander observe --app Finder --until 'role=AXWindow title~=Downloads' --timeout-ms 10000
screencommander observe --app Safari --events focus,window
```

- Streams UI changes as NDJSON, one `{ ts, event, app: { pid, name }, element? }` object per line, so an agent can wait for an outcome instead of polling screenshots. It always prints one-line JSON. `--app` is required.
- `--events` picks categories (default all): `value` (a value changed), `focus` (the focused element changed), `window` (created, moved, resized, or retitled), `destroy` (an element was destroyed), and `app` (the target app launched, activated, or quit).
- Runs until Ctrl-C (exit `0`), until `--timeout-ms` passes, or until `--until` matches.
- `--until '<predicate>'` stops when an element matches. A predicate is space-separated `key<op>value` conditions, where `key` is `role`, `title`, `value`, or `id`, and `<op>` is `=` (exact) or `~=` (contains, ignoring case). `id` matches only the first scan of the tree, which also makes a condition that is already true return at once. On a match it prints `{ "matched": true, "element": ... }` and exits `0`.
- With `--until`, a predicate still unmet when `--timeout-ms` runs out exits `73` (`observe_timeout`). `--timeout-ms` without `--until` exits `0`.

### Sequence

```bash
screencommander sequence --file ./sequence.json
```

```json
{
  "steps": [
    { "click": { "x": 935, "y": 1074, "meta": "./last-screenshot.json" } },
    { "scroll": { "x": 935, "y": 800, "dy": -4 } },
    { "move": { "x": 935, "y": 700, "dwellMs": 100 } },
    { "type": { "text": "hello from sequence", "app": "TextEdit" } },
    { "sleep": { "ms": 100 } },
    { "keys": { "steps": ["down:shift", "press:tab", "up:shift"], "app": "TextEdit" } },
    { "key": { "chord": "enter", "app": "TextEdit" } }
  ]
}
```

- Runs the steps in order and stops at the first failure. Each step has exactly one key: `click`, `scroll`, `drag`, `move`, `type`, `key`, `keys`, `selectText`, `action`, `launch`, or `sleep`.
- The whole file is checked before the first step runs. A step key or field that does not exist fails with `invalid_arguments` and names the step number and the key, so a mistyped `app` cannot send input to some other app.
- Step fields use the MCP tools' names, which are the CLI options in camelCase: `elementId`, `windowId`, `strictMetadata`, `durationMs`, `dwellMs`, `delayMs`, `timeoutMs`, and so on. The older spellings `durationMS`, `dwellMS`, `delayMS`, and `timeoutMS` still work. Input steps accept `app`, `windowId`, `foreground`, `session`, and `agentCursor`. `click`, `scroll`, and `type` steps accept `element`, `elementId`, `role`, `via`, and `strict`. `type` steps accept `mode` and `replace`, and `scroll` steps accept `direction` and `pages`.
- `selectText` steps take `range` (`{ "location": 0, "length": 5 }`) or `text`. `action` steps take `name`. `launch` steps take `app`, `timeoutMs`, and `session`. `keys` steps take `steps`, an array in the `keys` command's format. `sleep` takes `ms`, up to 3600000.
- `--session` and `--no-agent-cursor` on the command apply to steps that do not set their own.
- Each step gets its own before and after captures. A step's `noDiff: true` skips its comparison.

### Windows

```bash
screencommander windows
screencommander windows --app Safari --json
```

- Lists on-screen windows, one per line: `[windowID] AppName: "title" (WxH at X,Y, layer=N)`.
- `--app` takes an app name (exact or prefix) or a pid. An unknown app exits `81` (`app_not_found`).
- Needs Screen Recording.

### Apps

```bash
screencommander apps
screencommander apps --running-only
screencommander apps --filter safari --json
```

- Running apps show name, bundle ID, pid, whether each is frontmost, its count of on-screen normal windows, and its activation policy.
- Installed apps come from `/Applications`, `/System/Applications`, and `~/Applications`, one folder deep. The scan stops at 2000 bundles and is cached for 60 seconds per process. `--running-only` skips it.
- `--filter` keeps apps whose name or bundle ID contains the text, ignoring case.

### Launch

```bash
screencommander launch --app TextEdit
screencommander launch --app com.apple.TextEdit --timeout-ms 20000 --json
```

- Launches an app without activating it and waits until it is running. `--app` takes a name, bundle ID, or path to an `.app`.
- An app that is already running is reported with `alreadyRunning: true` and is not relaunched.
- Waits up to `--timeout-ms <1...120000>` (default `10000`). `ready` reports whether the app finished launching.
- The focus guard covers the launch for 5 seconds, and again once the app is ready, so an app that activates itself while starting goes back behind the previous app. `--session` names the session whose guard covers it. The `focus` receipt shows whether the frontmost app changed.
- While the abort key is in force it fails with `aborted_by_user` and launches nothing.

### Focus

```bash
screencommander focus --app Safari
screencommander focus --app 1234 --json
```

- Brings an app to the front and prints `Focused <AppName> (was: <PriorAppName>)`. `--app` takes an app name (exact or prefix) or a pid. An unknown app exits `81`.
- Input commands do not need it. Use it only when you want the app in front.
- While the abort key is in force it fails with `aborted_by_user` and leaves the frontmost app alone.

### Resume

```bash
screencommander resume
```

- Clears the stop set by the abort key (Control-Option-Command-Period) and says whether agent input had been stopped.
- When presence is not running there is nothing to resume, and the JSON result has `resumed: false`.

### Cleanup

```bash
screencommander cleanup --older-than-hours 24
```

Deletes `png`, `jpg`, `jpeg`, and `json` files in `~/Library/Caches/screencommander/captures` older than `--older-than-hours` (default `24`). No other command prunes captures.

### Serve

```bash
screencommander serve --mcp
```

Point your MCP client at the command `screencommander serve --mcp`. The server speaks the Model Context Protocol over stdio, as newline-delimited JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`). Diagnostics go to stderr.

- Tools: `screenshot`, `click`, `type`, `key`, `keys`, `scroll`, `drag`, `move`, `elements`, `app_state` (CLI `state`), `select_text` (CLI `select-text`), `perform_action` (CLI `action`), `list_apps` (CLI `apps`), `launch_app` (CLI `launch`), `windows`, `focus`, `observe_wait`, `doctor`, and `cleanup`. `sequence` and `resume` are CLI only.
- Tool results are the same JSON envelopes the CLI prints, as `structuredContent` plus a text block, so [docs/json-output-schema.md](docs/json-output-schema.md) covers both. One engine instance serves every call, with no process startup per action.
- Action tools take `app`, `windowId`, `foreground`, `session`, and `agentCursor`. `select_text` and `perform_action` take no `foreground`, since they only use `ax`. The server's session ID is `serve-<pid>` unless `SCREENCOMMANDER_SESSION` is set, and input to the same app is serialized so parallel calls never interleave.
- `screenshot` and `app_state` also return the capture as an MCP image content block (base64), so clients get the pixels without reading a file.
- `app_state` returns a delta after the first call for a window: changed records and `removedIds` against the previous `app_state` of that window. Pass `full: true` for the whole tree, or `since` to pick the baseline.
- `elements` accepts `profile`, `maxVisited`, and `timeoutMs`. `snapshot: true` keeps a bounded snapshot and returns its `snapshotId`, and `since: "<snapshotId>"` returns changed records and `removedIds`. Each delta comes from a fresh read. A missing, evicted, or incompatible snapshot returns the full tree with `resetReason`, and an incomplete read never becomes a baseline. IDs stay positional, so resolve them fresh before acting.
- Action tools accept `postObserve: {"app": "<name|pid>"}` to return one bounded accessibility read after delivery in the same call, tuned by `profile`, `since`, `maxElements`, `maxVisited`, and `timeoutMs`. A failed read reports `observationError` and keeps the action result. Do not repeat the action because of it. The read happens right after delivery, so a UI that changes asynchronously may not have settled.
- `observe_wait` wraps `observe --until` with a required `timeoutMs` of 1 to 600000. An unmet predicate is an `observe_timeout` error (`exitCode` `73`) that still carries the collected events in `result`.
- Requests run in parallel. A request that must wait for another can put `dependsOn` with the upstream request ID in its `params`. `notifications/cancelled` with `params.requestId` cancels that request and anything queued behind it.
- Window and display lists are cached for 2 seconds in serve mode, and simultaneous misses share one fetch. Numeric window targets are checked against current geometry before the cache is reused, app-name targets always resolve fresh window order, and a moved or resized window or a changed display forces a refresh. The CLI always enumerates fresh. Pixels are always captured anew.

## Scripting with JSON output

Every command can print exactly one JSON object to stdout, on success or failure.

- Add `--json` to a command, or put `--output json` before the subcommand, or set `SCREENCOMMANDER_OUTPUT=json`. A command's `--json` wins over `--output`, which wins over the environment variable.
- `--compact` (or `SCREENCOMMANDER_JSON_COMPACT=1`) prints the JSON on one line.
- A success envelope has `"status": "ok"`, `command`, `result`, and `exitCode`. An error envelope has `"status": "error"`, `command`, `error.code`, `error.message`, and `exitCode`. Read stdout once and branch on `status`.
- `observe` always prints NDJSON instead.

```bash
screencommander doctor --json
screencommander --output json screenshot --out /tmp/cap.png
SCREENCOMMANDER_OUTPUT=json screencommander cleanup --compact
```

For the fastest action calls, combine `--json --compact --no-postshot`. Use `--no-diff` alone when you want the captures without the comparison. The full contract, with every `result` shape, is in [docs/json-output-schema.md](docs/json-output-schema.md).

## Screenshot metadata

```json
{
  "capturedAtISO8601": "2026-02-20T12:34:56.789Z",
  "displayID": 69733248,
  "displayBoundsPoints": { "x": 0, "y": 0, "w": 1512, "h": 982 },
  "imageSizePixels": { "w": 3024, "h": 1964 },
  "pointPixelScale": 2,
  "imagePath": "/absolute/path/to/Screenshot-20260220-123456-1a2b3c4d.png"
}
```

A window capture adds `windowID` and `windowBoundsPoints`, the window's bounds in global points with a top-left origin.

## Environment variables

| Variable | Effect |
|----------|--------|
| `SCREENCOMMANDER_OUTPUT` | `human` or `json`. Default output format. |
| `SCREENCOMMANDER_JSON_COMPACT` | `1` prints JSON on one line. |
| `SCREENCOMMANDER_STATE_DIR` | State directory for captures, `last-screenshot.json`, profiles, and the presence socket. Default `~/Library/Caches/screencommander`. |
| `SCREENCOMMANDER_SESSION` | Default session ID for leases. |
| `SCREENCOMMANDER_AGENT_CURSOR` | `0` turns off the agent cursor. |
| `SCREENCOMMANDER_PRESENCE` | `0` turns off the presence process: no cursor, leases, focus guard, yielding, or abort key. |
| `SCREENCOMMANDER_KEEP_AWAKE` | `0` stops screencommander from keeping the display awake during a session. |
| `SCREENCOMMANDER_LEASE_IDLE_MS` | How long a session may leave an app alone before its lease ends. Default `15000`, from `500` to `600000`. |
| `SCREENCOMMANDER_CURSOR_LINGER_MS` | How long the agent cursor stays after the session's last action. Default `10000`, from `0` to `120000`. |

`SCREENCOMMANDER_AGENT_CURSOR`, `SCREENCOMMANDER_PRESENCE`, and `SCREENCOMMANDER_KEEP_AWAKE` also accept `false`, `off`, and `no`.

## Exit codes

| Code | `error.code` | Meaning |
|------|--------------|---------|
| `10` | `permission_denied_screen_recording` | Screen Recording is not granted. |
| `11` | `permission_denied_accessibility` | Accessibility is not granted. |
| `20` | `capture_failed` | The capture failed. |
| `21` | `image_write_failed` | The image could not be written. |
| `22` | `capture_timeout` | A capture took longer than 5 seconds. |
| `30` | `metadata_failure` | Metadata could not be read or written. |
| `40` | `invalid_coordinate` | A coordinate is out of range. |
| `41` | `mapping_failed` | A coordinate could not be mapped to the screen. |
| `50` | `input_synthesis_failed` | An input event could not be created or posted. |
| `51` | `background_delivery_unavailable` | No background tier can reach the target. The message says why. |
| `52` | `target_busy` | Another session holds the lease on the target app. |
| `53` | `aborted_by_user` | The abort key stopped agent input. Run `screencommander resume`. |
| `54` | `user_interrupted` | The user kept working in the target app, so nothing was delivered. |
| `60` | `invalid_arguments` | Invalid arguments or an unparseable chord. |
| `70` | `element_not_found` | `--element` or `--element-id` matched nothing. |
| `71` | `ax_tree_unavailable` | The app exposes no usable accessibility tree. |
| `72` | `element_not_actionable` | The element is disabled, or cannot take the action or tier asked for. |
| `73` | `observe_timeout` | The `--until` predicate was not met within `--timeout-ms`. |
| `80` | `window_not_found` | The window ID or name matched nothing. |
| `81` | `app_not_found` | The app name or pid matched no app. |
| `82` | `element_ambiguous` | `--element` matched several candidates. Use `--element-id`, `--role`, or `--app`. |
| `83` | `stale_metadata` | `--strict-metadata` found metadata that no longer matches the screen. |
| `84` | `window_minimized` | A minimized window could not be captured. |

## Development

```bash
swift build
swift test
swift run screencommander <command> --help
```

`bench/README.md` describes the performance and capture benchmarks.
