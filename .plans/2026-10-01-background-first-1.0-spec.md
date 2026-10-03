# ScreenCommander spec: background-first control and the agent cursor

**Date:** 2026-10-01
**Scope:** Make every command work on a background app without activating it or moving the real cursor, add an agent-owned on-screen cursor, and add the capabilities that put screencommander ahead of OpenAI's Sky computer use. This is the feature set for 1.0.
**Branch:** This repo

---

## 1. Objective

Sky, the computer-use service inside ChatGPT.app, does two things screencommander does not.

1. It shows a second cursor that belongs to the agent and leaves the user's cursor alone.
2. It clicks, types, scrolls, captures, and reads the AX tree of background apps without taking focus.

This spec brings both to screencommander and then goes further with focus receipts, per-app delivery profiles, concurrent sessions, user-yield, and a one-call app state.

Decisions already made by Stephen on 2026-10-01:

- Private SkyLight calls resolved with `dlsym` are acceptable in the shipped binary.
- Background delivery is the default. Bringing an app forward is opt-in with `--foreground`.
- The cursor runs from the same `screencommander` binary. There is no separate helper bundle.

Not in scope: locked-screen operation, OCR, screenshot downscaling, code signing and notarization, and the version bump to 1.0.0.

---

## 2. What the research found

### 2.1 Sky's background input

Read from the disassembly of `SkyComputerUseService` 0.7.5.

- Mouse events are ordinary `CGEvent`s. Sky sets field 3 to the button, field 7 to the subtype, and fields 91 and 92 to the target window ID. It sets a window-local location through one private call, then posts with public `CGEventPostToPid`.
- Keyboard events use `CGEventCreateKeyboardEvent` and `CGEventKeyboardSetUnicodeString`, posted per process. `set_value` writes `AXValue`.
- `SyntheticAppFocusEnforcer` posts activation and key-focus events to the target process so it believes it is active. The real frontmost app does not change.
- `SystemFocusStealPreventer` watches for apps that grab focus and puts the previous app back.
- Capture is `SCScreenshotManager` with `SCContentFilter(desktopIndependentWindow:)`.
- AX reads use `AXUIElementCreateApplication` per pid, batched attribute copies, and `AXEnhancedUserInterface` as a scoped assertion that is cleared afterwards.
- No Sky binary carries a private entitlement. Developer ID signing plus Accessibility and Screen Recording grants are enough.

### 2.2 Sky's cursor

- One small borderless `NSWindow` titled "Software Cursor" with `ignoresMouseEvents`, a clear background, and collection behavior `[.transient, .ignoresCycle, .canJoinAllApplications]`.
- The window copies the target window's level and orders itself directly above the target. It overrides `constrainFrameRect` so AppKit never clamps it.
- It re-reads the target window bounds every frame and follows the window.
- Motion is a spring-driven progress value along a cubic Bézier path. Damping is 0.9. The response time is clamped between 0.12 s and 2.2 s. The click fires at 99.5% progress or within about 3 pt.
- Fade in and out takes 0.44 s.
- Sky never calls `CGWarpMouseCursorPosition` or any cursor association API.
- Sky does not exclude the cursor from display captures. It relies on window-only capture.

### 2.3 Prior art that fills the gaps

- yabai and AltTab publish the "focus without raise" record. It is a 0xF8-byte event record posted with `SLPSPostEventRecordTo`, once to defocus the old window and once to focus the new one.
- cua's driver adds `SLEventPostToPid` with an authentication message for keyboard delivery into Chromium and Electron on macOS 15 and later. It also sends a `mouseMoved` primer before each click and stamps field 40 with the target pid.
- `sharingType = .none` is unreliable against ScreenCaptureKit on macOS 15 and later. Excluding the window through `SCContentFilter` is the reliable route.

### 2.4 Where screencommander stood at 46fbc42

- `key`, `keys`, and `type` post to the global HID tap. Keystrokes land in the frontmost app.
- A default coordinate click activates the target app.
- `--no-cursor` exists only on `click` and `scroll`. `drag` and `move` always move the real cursor.
- Events use the `.hidSystemState` source, so modifiers the user is holding leak into synthesized events.
- No process runs an AppKit run loop, so nothing can own a window.
- One private symbol is linked, `_AXUIElementGetWindow`.

---

## 3. Design

### 3.1 Delivery ladder

Every input action resolves a target `(pid, windowID)` and tries tiers in order.

| Tier | `deliveryMethod` | What it does |
|------|------------------|--------------|
| 1 | `ax` | AX action or attribute write on the element |
| 2 | `window` | Window-stamped `CGEvent` posted to the pid |
| 3 | `focusAssisted` | Synthetic focus records to the target, then tier 2, using `SLEventPostToPid` where the profile calls for it |
| 4 | `global` | HID tap delivery with activation. Only with `--foreground` |

Rules:

- Without `--foreground` the engine never activates an app, never posts to the HID tap, and never moves the hardware cursor. If no background tier applies it fails with error code `background_delivery_unavailable`.
- Target resolution for coordinate actions with no `--app` uses the window from the last screenshot metadata when present, then a window hit-test at the point. Keyboard actions with no target go to the frontmost app's pid.
- All synthesized events use a private event source state and set flags explicitly, so the user's held modifiers never leak in.
- A click is a `mouseMoved` primer, then down, then up, with short gaps.
- `--no-cursor` stays as an accepted alias with no effect, so existing scripts keep working.
- `click`, `type`, `key`, `keys`, `scroll`, `drag`, and `move` all take `--app`, `--window-id`, and `--foreground`, across the CLI, MCP tools, and `sequence` steps.

### 3.2 Private API softlinks

One file owns every private symbol. Each is resolved with `dlsym`, optional, and reported by `doctor`.

- `CGEventSetWindowLocation`
- `SLEventPostToPid` and the `SLSEventAuthenticationMessage` class
- `SLPSPostEventRecordTo`, `_SLPSGetFrontProcess`, `GetProcessForPID`
- `_AXUIElementGetWindow`, moved here from its current `@_silgen_name` declaration

When a symbol is missing, the tier that needs it is skipped.

### 3.3 Focus receipts

Each action result gains a `focus` object.

```json
"focus": {
  "preserved": true,
  "frontmostBefore": "com.apple.Terminal",
  "frontmostAfter": "com.apple.Terminal",
  "cursorMoved": false
}
```

The engine samples the frontmost app and cursor location before delivery and again after a short settle. It reports what it observed. `docs/json-output-schema.md` documents the object.

### 3.4 Per-app delivery profiles

`doctor --app <name>` classifies an app by toolkit and reports which tier the ladder will use and why. Classification is static. It reads the bundle for Chromium or Electron frameworks, Catalyst, Qt, Java, and game engines. It does not send input. Profiles are cached under the state directory, keyed by bundle ID and version. Apps with no background path, such as games and canvas apps, return `background_delivery_unavailable` with the reason.

### 3.5 Presence process

The same binary runs a hidden `presence` subcommand that stays alive. The CLI and `serve` start it on demand and it exits after an idle period.

It owns:

- **The cursor window.** Built to the recipe in 2.2 with public AppKit. One cursor per session, each with its own color. States are idle, loading, and paused.
- **The focus guard.** After a background action it watches `NSWorkspace.didActivateApplicationNotification` for a short lease. If the target app grabs focus it reactivates the previous app.
- **The user-input tap.** A listen-only event tap. When real input reaches an app that a session controls, the session is marked `userActive`.
- **The abort key.** Control-Option-Command-Period marks every session aborted. Actions fail with `aborted_by_user` until `screencommander resume`.
- **Leases.** One lease per target app per session, so two agents do not drive the same app at once.

The code lives in its own SwiftPM library target, `ScreenCommanderPresence`, linked into the one executable. Transport is a Unix domain socket under the state directory carrying newline-delimited JSON.

Messages:

| Message | Purpose |
|---------|---------|
| `hello` | Version check |
| `session.acquire`, `session.release` | Lease on a target pid |
| `cursor.moveTo` | Glide to a global point above a window. Replies when close enough |
| `cursor.press`, `cursor.setState`, `cursor.hide` | Click squash, activity state, hide |
| `guard.begin`, `guard.end` | Focus-steal lease around an action |
| `status` | `userActive`, `aborted`, overlay window IDs, sessions |
| `resume`, `shutdown` | Clear the abort flag, stop the process |

The client uses short timeouts. If the presence process is unreachable, actions still run and the result reports `presence: "unavailable"`.

`--no-agent-cursor` and `SCREENCOMMANDER_AGENT_CURSOR=0` turn the cursor off.

### 3.6 Sessions and serialization

- A session ID comes from `--session`, then `SCREENCOMMANDER_SESSION`, then the `serve` process, then a default.
- Inside `serve`, an actor serializes input per target pid so parallel tool calls cannot interleave events.
- Across processes the presence lease does the same job. A second session asking for a leased app gets `target_busy`.

### 3.7 Yield to the user

Before delivering, the engine asks presence for status. If the user is active in the controlled app it waits for a quiet period of up to one second per check, up to a timeout, then fails with `user_interrupted`. The cursor shows the paused state while it waits.

### 3.8 Capture

- Display captures pass the presence overlay window IDs to `SCContentFilter(display:excludingWindows:)`. This keeps the cursor out of screenshots, pre and post shots, and frame diffs.
- Window captures are unchanged.

### 3.9 Sky parity tools

| Capability | CLI | MCP tool |
|------------|-----|----------|
| AX tree and window screenshot in one call, tree as a diff when a prior snapshot exists | `state --app` | `app_state` |
| Running and installed apps | `apps` | `list_apps` |
| Launch without activating | `launch --app` | `launch_app` |
| Select text in an element | `select-text` | `select_text` |
| Any AX action the element lists | `action --element --name` | `perform_action` |
| Scroll an element by direction and pages | `scroll --element --direction --pages` | `scroll` |
| Background drag | `drag --app` | `drag` |

`AXEnhancedUserInterface` becomes a scoped assertion that is always cleared after the read.

---

## 4. Execution phases

1. **Delivery ladder.** Softlinks, input backends, engine tiers, `--foreground`, focus receipts, CLI, MCP, and sequence plumbing, tests.
2. **Presence module.** The `ScreenCommanderPresence` target with cursor window, motion, socket protocol, focus guard, event tap, leases, and client. Built in parallel with phase 1.
3. **Integration.** The `presence` subcommand, engine hooks, sessions, yield, abort and `resume`, capture exclusion.
4. **Parity tools and profiles.** Section 3.9 and `doctor --app`.
5. **Docs.** README, SKILL.md, `docs/json-output-schema.md`, command help.
6. **Install and live test.** `scripts/install.sh`, then every capability exercised against apps the test launches itself.

---

## 5. Risks and open items

- **Keyboard into background Chromium and Electron.** The middle tiers follow yabai's and cua's published recipes. One public teardown saw Sky itself blink focus when typing into Chrome. Live results per toolkit go in the test report.
- **Private API drift.** Apple can change any softlinked symbol. `doctor` reports availability and the ladder skips tiers that need a missing symbol.
- **Posted is not delivered.** An app can ignore a per-process event. Element actions verify by re-reading AX state. Coordinate actions report `verified: "unknown"`.
- **TCC on an unsigned binary.** Grants may not survive a rebuild. Signing and notarization are a release task outside this spec.
- **Asynchronous activation.** An app can activate itself after the receipt is sampled. The focus guard covers a few seconds after each action.

---

## 6. Implementation notes

Written after phases 1 to 5. These are the places where the code differs from the design above. README, SKILL.md, and `docs/json-output-schema.md` describe the code.

**Delivery ladder (3.1)**

- `--via` exists on `click`, `scroll`, and `type` only, in the CLI, MCP, and `sequence`. `drag`, `move`, `key`, and `keys` take `--app`, `--window-id`, `--foreground`, `--session`, and `--no-agent-cursor`, with no `--via`.
- `--no-cursor` stayed only on `click` and `scroll`, where it was before. It is hidden from help and has no effect.
- `--via pid` is accepted as an alias for `window`, and results report it as `window`.
- Tier order depends on the app's profile. Chromium, Electron, Qt, and Java apps try `focusAssisted` before `window`. Other apps try `window` first.
- Keyboard input to an app with no on-screen window uses the `window` tier without a window stamp, posting to the pid. A background Command shortcut is the exception: it needs a key window, so without an on-screen window it can only reach a menu item through `ax`, and a non-menu Command chord is refused.
- With `--foreground`, coordinate actions and keyboard actions without an element skip the background tiers and use `global` directly, which keeps the pre-1.0 behavior. Element actions keep the ladder and add `global` at the end. `--foreground` actions draw no cursor and begin no guard, but they stop for the abort key, lease their target when one is known (the app `--app` or `--window-id` names, else the last screenshot's window, else the topmost window at the point), wait until no real input of any kind arrived for a quiet second, and report `presence: "active"`. They hold one serializer key shared by all HID tap delivery plus their target's pid key.
- The `ax` tier for `scroll` exists only for page scrolls (`--direction`). Delta scrolls on an element use the event tiers.
- System and media keys fail with `background_delivery_unavailable` without `--foreground`. So do the `spotlight`, `raycast`, and `missioncontrol` aliases, since they name system-wide shortcuts. The chords they stand for (`cmd+space`, `f3`), typed out, go to the target app as asked.
- `sequence` gained `selectText`, `action`, and `launch` steps. It has no `keys` step.
- Background Command shortcuts work through `key`. The focus record alone left the app active with no key window, so AppKit menu commands and view shortcuts were dropped. `focusAssisted` now also makes the window key by posting one click addressed to a point outside the window frame (`KeyWindowPrimer`), which AppKit and Chromium turn into a key-window change without any visible effect. `key` with a Command chord first resolves the chord against the target app's AX menu bar (`AXMenuBar`, matching `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey`, and `AXMenuItemCmdModifiers`, skipping the Apple menu). A match is pressed with `AXPress` once its window is key and the item reads enabled, reported as `deliveryMethod: focusAssisted` with `menuItem` naming it and `verified: true`. An item that still reads disabled gets the chord as key events so AppKit revalidates it, then is read back: still disabled fails `element_not_actionable`. A chord that is no menu item is sent as key events in the key window. A chord that resolves to no menu item and cannot reach a key window (no on-screen window, or missing focus-record symbols) fails `background_delivery_unavailable`. With no key window possible, a menu item is still pressed through `ax` when it reads enabled. The menu map is cached per pid for 5 seconds (for `serve`); `AXEnabled` is read fresh at press time. `keys` does not resolve menu items, but a sequence that holds Command uses `focusAssisted` alone so its chords reach a key window. Background `type` still sends Unicode key events whatever `--mode` says and never touches the pasteboard. Paste mode runs only with `global` delivery.
- A window that is not on screen (minimized, its app hidden, or on another Space) gets no mouse events. A coordinate action addressed to one, through `--window-id` or screenshot metadata, fails with `background_delivery_unavailable` instead of hit-testing the point. Element actions keep the `ax` tier, and keys go to the pid without a window stamp.
- Hit tests skip the agent cursor's own windows, which sit at the target window's level.

**Private symbols (3.2)**

- `SLEventSetAuthenticationMessage` is resolved as well. `doctor` lists eleven symbols, with `GetProcessPID`, `SLSHWCaptureWindowList`, and `SLSGetWindowBounds` added later.
- `PrivateAPI.eventRecord(of:)` no longer returns the first non-nil pointer at offsets 24, 32, 16. It reads only within the CGEvent's own allocation (`malloc_size`), and a candidate is used only when it points to a live heap block at least `0xF8` bytes long whose header holds the record length at byte 4 and the event's type at byte 8 (`isEventRecord`). When no candidate checks out, `postAuthenticated` returns false and keyboard delivery falls back to plain `CGEventPostToPid`, so a changed CGEvent layout never hands SkyLight a garbage pointer.

**Verification (section 5, "Posted is not delivered")**

- Element clicks through `ax` report `verified: "unknown"`. Only `type` into an element or a focused text field, page scrolls, and `select-text` read state back. Everything else reports `"unknown"`.

**Focus receipts (3.3)**

- The after-sample is taken about 60 ms after delivery. Apps are identified by bundle ID, or by name when there is none. `cursorMoved` is true for any movement over half a point, including the user's own mouse.
- The receipt gained `guardRestored`. When the presence focus guard restored the previous app during the action (the smallest addition to the protocol: a `guardRestores` array on `status`, each entry a pid with a restore count and milliseconds since the last restore), the receipt sets `guardRestored: true` and `preserved: false`, so a restore that lands before the after-sample is visible rather than reading as preserved. It is absent when presence did not take part. `guardRestores` is optional on the wire, so a presence process from an older build (client and server are the same binary, but an older `serve` or `presence` may still be running) decodes as nil and the receipt leaves `guardRestored` unset.

**Delivery profiles (3.4)**

- Profiles have a support level: `supported`, `degraded`, or `unsupported`. Only AppKit and SwiftUI apps are `supported`, since they are the only toolkit verified on both Macs with no open question. Chromium and Electron are `degraded`. Their reasons say where each was verified (Electron on macOS 15 and 27.2, Google Chrome on 27.2), what was not tested, and that window-addressed input reaches only the window's active tab. Catalyst, Qt, Java, and bundle-less apps are `degraded` because they were never tested. Game engines are `unsupported`. A missing `CGEventSetWindowLocation` degrades every app.
- For a Chromium or Electron app, plain `window` events are not a silent fallback: the window drops them while it is not key, so they would report success while nothing happened. The profile lists `focusAssisted` only, and `--via window` can still force the plain path. Mouse and keyboard tiers both require a window location now, because the key-window primer is a window-addressed click even for keyboard delivery.
- `--via` overrides an `unsupported` profile and can force a tier a profile leaves out, as does `--foreground`. AX actions are tried for every profile.
- `doctor --app <name>` prefers an installed app with exactly the requested name over a running process matched by prefix, and the app resolver never lets a prefix match a background-only service (activation policy `prohibited`), so `doctor --app Cursor` with Cursor not running no longer resolves to `CursorUIViewService`.
- The cache key also includes a rules version, so old entries are ignored when the classifier changes.

**Presence (3.5 to 3.7)**

- The socket is `presence.sock` in the state directory. When that path is longer than the 103 bytes a Unix socket allows, every process uses `/tmp/screencommander-<uid>/presence-<FNV-1a hash of the state directory>.sock`. The directory must be owned by the user with mode 0700, or presence refuses to start.
- When presence fails to start, the reason is written to `presence-start-error.txt` in the state directory and shown by `doctor`. A successful start removes it. `doctor` also reports when `SCREENCOMMANDER_PRESENCE=0` disables presence.
- Presence exits after 120 seconds with no session, no guard, and no abort. Open connections do not count. A lease ends once its session has not acted on the app for 15 seconds (`SCREENCOMMANDER_LEASE_IDLE_MS`), connected or not. CLI leases survive their process until then. `serve` acquires with no hold, so its leases end when its connection closes. A session ends when it holds no lease, and its cursor fades 10 seconds after its last request (`SCREENCOMMANDER_CURSOR_LINGER_MS`). Protocol version 2: `hello` always answers with the server's version, a client replaces only an older server, and `shutdown` is refused from a client that did not greet with version 2 or later.
- The focus guard lasts 3 seconds per action and 5 seconds around `launch`. It ignores an activation when any real input (keys, modifiers, buttons, motion, scrolls, gestures) or a Space change came within 1.5 seconds before it, restores the app the activation deactivated, re-samples the frontmost app on every renewal, and restores at most three times per action. The HID idle fallback reads only the event types the window server tracks for hardware input: `kCGAnyInputEventType` and untracked types report overall idle time, which screencommander's own per-pid posts reset. `focus` and `--foreground` send `guard.end` for their target before activating it.
- Presence does not idle out while the abort flag is set, since the flag lives only in that process.
- Yielding waits for a 1 second quiet period, checks at most once per second, and gives up after 5 seconds with `user_interrupted`. Presence records the app each key press, click, scroll, and gesture went to (keys to the frontmost app, pointer events to the owner of the window under the pointer), with or without a lease, and the yield check reads that record for the target, so a session's first action on an app the user is typing in waits too. Every process that posts events talks to presence first, which registers its pid.
- The engine sets `loading` after each successful action that drew the cursor. The next action's yield check puts it back to `idle`, and the session's linger removes it.
- `resume` is CLI only. There is no MCP tool, so an MCP client cannot clear the user's abort.
- `--no-agent-cursor` is `agentCursor: false` in MCP and sequence steps.
- `doctor`, `resume`, and capture exclusion never start presence. `launch` starts it before launching so the guard is ready.

**Capture (3.8)**

- ScreenCaptureKit never returns from a capture of a window that is not on screen. Those windows (minimized, hidden app, other Space, full-screen Space) are captured with `SLSHWCaptureWindowList`. `state` falls back to a minimized or hidden-app window when the app has nothing on screen.

**Parity tools (3.9)**

- The CLI `state` always returns the full tree. MCP `app_state` returns a delta against the previous call for the same window, with `full` and `since` to override.
- `select-text` and `action` use `ax` only and take no `--foreground`. Their `--window-id` only picks the window the cursor glides over.
- `launch` reports an app that is already running instead of relaunching it.

**Live verification**

- Verified live against an AppKit test fixture (`bench/InputFixture.swift`): the `ax` and `window` tiers for `click`, `type`, `key`, `keys`, `scroll`, `move`, and `drag`, the `focusAssisted` tier for `click`, `type`, and `scroll` (forced with `--via`), `global` delivery with `--foreground`, paste mode with `--foreground` (every pasteboard item and type restored byte for byte), the agent cursor, leases, `target_busy` across two `serve` processes, presence exiting 120 seconds after its last client, and capture exclusion.
- Also verified live on that fixture: the cursor following a moving window and fading out while its window is minimized, hidden, or on another Space, the `loading` state, captures of minimized, hidden, other-Space, and full-screen-Space windows with a known pixel pattern, coordinate hit tests with and without window metadata, the focus guard putting the previous app back after the fixture activated itself, the guard leaving a simulated user click alone, yielding (`userActive`, `paused`, `user_interrupted` after 5 seconds, delivery after 1 quiet second), and the abort key with `resume`. Yielding, the abort key, and the user click came from an unregistered helper posting through the HID event tap, which presence treats as user input.
- Background Command shortcuts verified live on that fixture (before live testing was moved off this Mac): `cmd+a` and `cmd+k` resolved to the Edit and Fixture menu items and were pressed through `AXPress` (`deliveryMethod: focusAssisted`, `verified: true`), `cmd+shift+k` reached a menu item whose nil-targeted action only a key window routes, `cmd+j` reached a view's own `performKeyEquivalent` as key events, a disabled item (`cmd+shift+d`) and Select All while empty were refused with `element_not_actionable`, and a chord with no menu item (`cmd+b`) went out as key events. Every one left the focused window, focused element, frontmost app, and front-to-back window order unchanged.
- Window order checked live on the AppKit fixture: `focusAssisted` key and menu presses, `type`, `scroll`, and coordinate clicks all left the fixture window at the same depth and the owner's app frontmost. The focus-without-raise record plus the key-window primer do not reorder native windows.
- The forward-and-back the owner saw during Electron testing came from two things, both confirmed from logs: the Electron fixture's early launch ordered its window in front (a `showInactive()` without an immediate order-to-back), and a window-addressed coordinate click into Chromium web content made Chromium order its own window toward the front. Neither is the `focusAssisted` tier: keyboard, menu presses, and scrolling into the same Electron window left its stacking unchanged, and native AppKit windows were never reordered by any tier. Chromium raising its window on a content click is Chromium's own behavior; the frontmost app did not change.
- Electron delivery was exercised live on macOS 15 against the Electron fixture before testing moved to a second Mac: clicks, typing through each keyboard tier, keys, Command shortcuts, scrolling, `state`, and `screenshot --window`, with focus preserved. The accessibility text input and key-events-first ordering below came later and were verified on macOS 27.2 only. Electron and Chromium profiles stay `degraded`, and their reasons say what was verified and where.

**Second Mac run (macOS 27.2, arm64, Stage Manager on)**

- The AppKit checklist passed again: `cmd+a` as "Edit > Select All" with `verified: true`, `cmd+j` as view keys, the disabled `cmd+shift+d` refused with exit 72, and `focusAssisted` key, type, scroll, and click leaving the fixture at the same depth with the frontmost app unchanged. The closing regression passed: clicks by coordinate and element, type, key, keys, delta and page scrolls, move, drag, `select-text`, `action`, `state`, window captures while covered and hidden, the agent cursor drawn and kept out of display captures, `--no-agent-cursor`, `target_busy` between two CLI sessions, refusals, `serve` (19 tools, an `app_state` delta, parallel calls), `sequence`, and `observe`.
- Also verified for real there: the abort chord from an unregistered helper and `resume`, yielding (`paused`, delivery after a quiet second, `user_interrupted` after 5 seconds), the focus guard after the fixture activated itself on click (`guardRestored: true`, `preserved: false`), `--foreground` click, key, and paste on Calculator with every clipboard item restored, and `launch` of Calculator without activation.
- Electron 42 test app: `focusAssisted` clicks landed in the page, `--via window` clicks were dropped while the window was not key, typing worked through `window`, `focusAssisted`, and authenticated `SLEventPostToPid`, Delete, `cmd+a` and `cmd+s` (menu items) and a page's `cmd+j` worked, scrolling worked through `focusAssisted` and `window`, and `state` and a covered window capture were correct. The CGEvent record sits at offset 24 on macOS 15 and 27.2, so the authenticated path runs on both.
- The window raise seen on macOS 15 (a coordinate click into Chromium web content moving its window toward the front) did not happen on macOS 27.2. Plain `window` clicks, `focusAssisted` clicks (focus record, key-window primer, and click), right clicks, double clicks, and the default ladder all left the Electron window at the same depth, with an accessory window and a regular app's window in front of it. No change was made to the ladder. The macOS 15 behaviour was not retested, since nothing may run on that Mac, and stays unverified.
- Stage Manager reports the windows of other stages, and windows minimized into the strip, as on screen at their thumbnail's bounds. Coordinate clicks addressed to such a window went to the wrong local point and reported success. `CGWindowLocator` now compares the reported bounds with `SLSGetWindowBounds` (a new optional symbol) and marks a window whose reported size is under 90% of its frame as a Stage Manager thumbnail: not on screen for mouse events (`background_delivery_unavailable` naming Stage Manager), skipped by hit tests, and still a keyboard target, since key events and the key-window primer reach it. A thumbnail's capture is the thumbnail itself. Neither ScreenCaptureKit nor `SLSHWCaptureWindowList` returns a full-size image of it.
- The first accessibility read of a freshly started Electron app returned only the window frame (12 elements) because Chromium builds its tree about two seconds after `AXManualAccessibility` is first set. `AXReader.tree` now re-reads a Chromium-family app's tree every 250 ms, for up to 3 seconds, while it has no `AXWebArea`.
- With Stage Manager on, an inactive app's `orderFrontRegardless` switches stages, so the test fixtures were arranged with accessory windows, which join the current stage.
- `NSRunningApplication.activate()` from the SSH session did not activate the unbundled, accessory test executable on macOS 27.2, so `--foreground` there was tested on Calculator, which activated normally.
- While the screen is locked, accessibility reads return the application element as its own child, and input is not testable. Locked-screen operation stays out of scope.

**Text input (`type`)**

- The default `--mode` is now `unicode` in the CLI, MCP, and `sequence`. The clipboard is touched only by `--mode paste` with `global` delivery. `KeyboardController.typeByPasting` is the only code that reads or writes `NSPasteboard`.
- Tier `ax` inserts at the caret. `AXTextInput` writes `AXSelectedText` and reads `AXValue` back against the expected splice. When the value is unchanged (Chromium accepts the write and ignores it), it splices the text into `AXValue` and sets the caret after it. When the value changed to something else, it reports `verified: false` and does not fall through, so text is never typed twice. When it is refused or unchanged, `type` falls back to key events. Secure fields are written but never read, and report `"unknown"`.
- Without an element, tier `ax` uses the app's `AXFocusedUIElement` when it is a text field, text area, combo box, or has a settable `AXSelectedText` (and, with `--window-id`, sits in that window). Electron reports no focused element while its window is not focused, so `type` there goes to key events.
- `--replace` (MCP `replace`) writes `AXValue`. Its key-event fallback selects the whole value first. Element key fallbacks restore the caret that focusing the element may have moved.
- Line breaks go out as the Return key and tabs as the Tab key, each with its Unicode string, instead of on key code 0.
- Chromium and Electron: an `AXValue` write into an input or text area fires an input event (with no `inputType`) and the splice leaves the caret where typing would. A write into a contenteditable fires none, so a page editor would not see it. `type` therefore sends key events first for Chromium and Electron apps and keeps `ax` as the last tier, or the forced one with `--via ax`. Through key events the input, text area, and contenteditable all took an empty insert, a mid-string caret, a selection, `--replace`, and non-ASCII text, each with an `insertText` input event.
- Key events go through the system's text substitutions. On home-server "Add period with double-space" turned two spaces into ". " in a 3,000-character string, in AppKit and Electron alike. Nothing was dropped or reordered otherwise. Plain `window` keys into a non-key Electron window lost one of those spaces instead. A tab sent as the Tab key moves focus out of a web text area.
- Verified on macOS 27.2 on the AppKit text field: inserts into an empty field, at a mid-string caret, and over a selection through `ax`, the same through `window` and `focusAssisted`, `--replace` through `ax` and keys, and accented letters, emoji, and CJK through both paths. Each run left the clipboard change count, the frontmost app, and the window order unchanged, with `focus.preserved` true.

**Google Chrome (macOS 27.2)**

- Chrome 154 ran as a separate instance (`open -g -n` with a throwaway `--user-data-dir`) next to the owner's own Chrome, which was left alone. It loaded the dark test page from a short-lived local listener that recorded the page's events.
- Chrome does not take `AXManualAccessibility`, so priming falls back to `AXEnhancedUserInterface`, and the first read held only the browser frame (36 elements, no web area). `AXPriming.looksUnbuilt` now treats any Chromium tree without an `AXWebArea` as unbuilt, whatever its size, and the read waits for the page. Chrome's contenteditable reports the role `AXTextArea`.
- Passed: coordinate clicks through the default ladder and `focusAssisted`, element clicks through `ax`, `--via window` clicks dropped while the window was not key, and no change in stacking with an accessory window or another Chrome window in front. `type` into an input, a text area, and a contenteditable through the default ladder (key events), forced `ax`, `window`, and `focusAssisted`, `--replace`, and non-ASCII text, each with an input event and the clipboard untouched. An `AXValue` write into the contenteditable fired no input event, as in Electron. `key` (a letter, Delete, `cmd+a` as "Edit > Select All"), `keys`, delta and page scrolls, `select-text`, `state` and `elements` with the page content (647 elements), and a capture of the covered window. With a second tab active, clicks, typing, and keys reached only that tab.
- `key cmd+n` and `key cmd+t` pressed New Window and New Tab, and Chrome activated itself for both. The focus guard put Finder back and the receipts said `guardRestored: true`.

**Keeping the Mac awake**

- Presence holds a `PreventUserIdleDisplaySleep` assertion ("screencommander: an agent session is active") while any session exists. `PresenceCore` syncs it after every request, connection close, and tick, and releases it on `shutdown` and when the server tears down. `KeepAwake` wraps the assertion behind `PowerAssertionHolding` for tests. `SCREENCOMMANDER_KEEP_AWAKE=0` turns it off. `status` gained an optional `keepAwake`, which `doctor` shows.
- With presence disabled, `serve` holds its own assertion through `ActivityKeepAwake` for 120 seconds after each tool call, checked every 15 seconds.
- Verified on home-server: the assertion appeared in `pmset -g assertions` during a session and was gone once the lease and the session linger ran out. A `serve` with presence off held its own assertion after a tool call and dropped it on exit.

