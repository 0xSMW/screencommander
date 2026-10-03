// Compile with: swiftc -framework Cocoa bench/InputFixture.swift -o /absolute/path/input-fixture
// Run with: /absolute/path/input-fixture /absolute/path/input-log.jsonl [lifetime-seconds] [flags]
//
// Flags (any order after the positional arguments):
//   --allow-activation   stay frontmost when activated instead of handing focus back
//   --activate-on-click  activate the app on every left mouse-down (implies --allow-activation)
//   --pattern            fill the window with four solid dark quadrants (dark red, dark
//                        green, dark blue, dark yellow, clockwise from top-left; each
//                        channel 0 or 0x40) instead of controls, for pixel checks of
//                        captures
//   --front              order the window in front of other apps' windows at launch
//   --accessory          run as an accessory app (no Dock icon or menu bar). With Stage
//                        Manager on, an accessory app's window joins the current stage,
//                        so it can cover another app's window there
//   --second-window      add a second window ("ScreenCommander Input Fixture 2") with
//                        its own text field ("Second field"), a button ("Second
//                        button"), and a "Slow button" whose action blocks for 7 s,
//                        past the accessibility timeout. It opens over the first
//                        window's left half, and the first window stays key
//   --panel              add a floating inspector panel ("Fixture Inspector", window
//                        layer 3) with a "Panel button", shown while the app is inactive
//
// Commands: write one command per line to <log path>.cmd; the fixture reads and
// clears the file every 100 ms and logs each command it runs. Commands: front, back,
// move <dx> <dy>, glide <dx> <dy> <seconds>, minimize, deminimize, hide, unhide,
// fullscreen, activate, frame, quit. With --second-window: front2, back2,
// move2 <dx> <dy>, key1 and key2 (make that window key without activating the app).
// popup opens a context menu (items Alpha, Beta, Gamma; a choice logs popupAction)
// at the first window's center, at the pop-up menu window level.
//
// Every log line carries keyWindowNumber, the window number of NSApp.keyWindow (0
// when there is none), and text changes name their field.
//
// Menus and key equivalents, for Command-shortcut tests:
//   Edit > Cut, Copy, Paste, Select All (cmd+x/c/v/a), nil-targeted to the text field
//   Fixture > Fixture Action (cmd+k), targeted at the app delegate; logs menuAction
//   Fixture > Fixture Chain Action (cmd+shift+k), nil-targeted; only a key or main
//            window's delegate implements it, so it logs chainAction only when AppKit
//            routed it through a window
//   Fixture > Fixture Disabled (cmd+shift+d), always disabled by validation
// An editable multi-line text view ("Fixture notes") sits between the field and the
// scroll view and logs notesChanged with its text.
//   A view-level key equivalent: cmd+j is handled in performKeyEquivalent by a view
//   in the window (no menu item) and logs viewKeyEquivalent.
// Selection changes in the text field and menu tracking are logged too, and every
// line carries NSApp.keyWindow and NSApp.mainWindow presence.
//
// A disposable background-input target. It never activates itself and orders its
// window behind other windows, so it can be driven while another app stays
// frontmost. It always draws in the dark appearance, so it never lights up the
// screen of someone working at night. Every mouse, key, and scroll event the app receives is appended to the
// log as one JSON line, together with the app's active state and the window's key
// state at that moment. Control effects (button presses, text edits, scrolling) are
// logged too, so a caller can tell "event arrived" apart from "control reacted".
// Activation changes are logged; if anything really activates the fixture it hides
// itself at once, which returns focus to the previous app. SIGTERM terminates cleanly, and the
// fixture exits on its own after its lifetime (default 120 s) so no stray instance
// lingers if the driving run dies.
import AppKit
import Darwin
import Foundation

final class InputFixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let windowDelegate = FixtureWindowDelegate()
    private var textField: NSTextField!
    private var notesView: NSTextView!
    private var scrollView: NSScrollView!
    private var pressCount = 0
    private var log: FileHandle!
    private var monitor: Any?
    private var terminationSignal: DispatchSourceSignal?
    private var commandTimer: Timer?
    private var glideTimer: Timer?
    private var commandPath = ""
    private var secondWindow: NSWindow?
    private var secondField: NSTextField?
    private var panel: NSPanel?
    private var popupMenu: NSMenu?
    private let flags = Set(CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") })
    private var allowActivation: Bool { flags.contains("--allow-activation") || flags.contains("--activate-on-click") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        let path = positional.first ?? "input-fixture-log.jsonl"
        commandPath = path + ".cmd"
        FileManager.default.createFile(atPath: commandPath, contents: nil)
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)

        NSApp.setActivationPolicy(flags.contains("--accessory") ? .accessory : .regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // An Edit menu, so Command-V and friends reach the text field the way they
        // do in real apps (key equivalents are dispatched through the main menu).
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let fixtureItem = NSMenuItem()
        let fixtureMenu = NSMenu(title: "Fixture")
        let action = fixtureMenu.addItem(withTitle: "Fixture Action", action: #selector(fixtureAction(_:)), keyEquivalent: "k")
        action.target = self
        let chain = fixtureMenu.addItem(
            withTitle: "Fixture Chain Action",
            action: #selector(FixtureWindowDelegate.fixtureChainAction(_:)),
            keyEquivalent: "k"
        )
        chain.keyEquivalentModifierMask = [.command, .shift]
        let disabled = fixtureMenu.addItem(withTitle: "Fixture Disabled", action: #selector(fixtureDisabled(_:)), keyEquivalent: "d")
        disabled.keyEquivalentModifierMask = [.command, .shift]
        disabled.target = self
        fixtureItem.submenu = fixtureMenu
        mainMenu.addItem(fixtureItem)
        NSApp.mainMenu = mainMenu
        windowDelegate.log = { [weak self] entry in self?.write(entry) }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.write(["kind": note.name.rawValue])
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? NSTextView else { return }
            let range = view.selectedRange()
            self?.write(["kind": "selectionChanged", "location": range.location, "length": range.length, "textLength": view.string.utf16.count])
        }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 420, height: 320)
        let frame = NSRect(x: screen.maxX - size.width - 40, y: screen.minY + 40, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "ScreenCommander Input Fixture"
        window.isReleasedWhenClosed = false
        window.delegate = windowDelegate
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)

        let root = KeyEquivalentView(frame: NSRect(origin: .zero, size: size))
        root.log = { [weak self] entry in self?.write(entry) }
        window.contentView = root
        if flags.contains("--pattern") {
            let pattern = PatternView(frame: root.bounds)
            pattern.autoresizingMask = [.width, .height]
            root.addSubview(pattern)
        }

        if !flags.contains("--pattern") {
        let button = NSButton(frame: NSRect(x: 16, y: 270, width: 160, height: 32))
        button.title = "Fixture button"
        button.setAccessibilityLabel("Fixture button")
        button.target = self
        button.action = #selector(pressed)
        root.addSubview(button)

        textField = NSTextField(frame: NSRect(x: 190, y: 274, width: 210, height: 24))
        textField.placeholderString = "Fixture field"
        textField.setAccessibilityLabel("Fixture field")
        textField.delegate = self
        root.addSubview(textField)

        // An editable multi-line text view, for typing tests that need line breaks.
        let notesScroll = NSScrollView(frame: NSRect(x: 16, y: 174, width: 388, height: 88))
        notesScroll.hasVerticalScroller = true
        notesView = NSTextView(frame: NSRect(x: 0, y: 0, width: 370, height: 88))
        notesView.isEditable = true
        notesView.isRichText = false
        notesView.setAccessibilityLabel("Fixture notes")
        notesView.delegate = self
        notesScroll.documentView = notesView
        root.addSubview(notesScroll)

        scrollView = NSScrollView(frame: NSRect(x: 16, y: 16, width: 388, height: 150))
        scrollView.hasVerticalScroller = true
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 370, height: 150))
        document.string = (0..<400).map { "Fixture scroll line \($0)" }.joined(separator: "\n")
        document.isEditable = false
        document.setAccessibilityLabel("Fixture scroll document")
        scrollView.documentView = document
        scrollView.setAccessibilityLabel("Fixture scroll view")
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        root.addSubview(scrollView)
        }

        if flags.contains("--pattern") {
            textField = NSTextField(frame: .zero)
            scrollView = NSScrollView(frame: .zero)
        }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.record(event)
            if event.type == .leftMouseDown, self?.flags.contains("--activate-on-click") == true {
                self?.write(["kind": "activatingSelf"])
                NSApp.activate(ignoringOtherApps: true)
            }
            return event
        }

        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.write(["kind": note.name.rawValue])
            }
        }
        // If anything really activates the fixture, it logs that and hands focus straight
        // back (hiding the active app activates the previous one), then reappears
        // inactive. A synthetic activation from focus records leaves another app
        // frontmost, and hiding then would move focus away from that app, so it is
        // only logged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.allowActivation == false,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                return
            }
            NSApp.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.unhideWithoutActivation()
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                self?.write(["kind": note.name.rawValue])
            }
        }

        let lifetime = positional.dropFirst().first.flatMap(TimeInterval.init) ?? 120
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            NSApp.terminate(nil)
        }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source

        // Never activate: show the window at the back of the stack and leave the
        // frontmost app alone.
        if flags.contains("--front") {
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
        makeExtraWindows(over: frame)
        window.makeFirstResponder(textField)
        // Like a real app's window that the user worked in before switching away: it
        // becomes key again whenever the app is made active, which is what
        // focus-without-raise relies on. This does not activate the app.
        window.makeKey()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollCommands()
        }
        RunLoop.main.add(timer, forMode: .common)
        commandTimer = timer

        var ready: [String: Any] = [
            "kind": "ready",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "windowNumber": window.windowNumber,
            "frameTopLeft": topLeft(window.frame),
        ]
        if let secondWindow {
            ready["secondWindowNumber"] = secondWindow.windowNumber
            ready["secondFrameTopLeft"] = topLeft(secondWindow.frame)
        }
        if let panel {
            ready["panelWindowNumber"] = panel.windowNumber
            ready["panelFrameTopLeft"] = topLeft(panel.frame)
        }
        write(ready)
        print("READY {\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"windowNumber\":\(window.windowNumber),"
            + "\"secondWindowNumber\":\(secondWindow?.windowNumber ?? 0),\"panelWindowNumber\":\(panel?.windowNumber ?? 0)}")
        fflush(stdout)
    }

    /// A frame in global top-left-origin points, the space screencommander uses.
    private func topLeft(_ frame: NSRect) -> [String: CGFloat] {
        let topLeftY = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
        return ["x": frame.minX, "y": topLeftY, "w": frame.width, "h": frame.height]
    }

    /// The second window, the inspector panel, and the context menu, when asked for.
    /// The second window covers the first window's left half (its button and the
    /// left of its field), and neither steals key status from the first window.
    private func makeExtraWindows(over frame: NSRect) {
        let menu = NSMenu(title: "Fixture popup")
        for title in ["Alpha", "Beta", "Gamma"] {
            let item = menu.addItem(withTitle: title, action: #selector(popupChosen(_:)), keyEquivalent: "")
            item.target = self
        }
        popupMenu = menu

        if flags.contains("--second-window") {
            let size = NSSize(width: 260, height: 200)
            let secondFrame = NSRect(x: frame.minX - 40, y: frame.maxY - size.height - 10, width: size.width, height: size.height)
            let second = NSWindow(contentRect: secondFrame, styleMask: [.titled, .miniaturizable, .resizable], backing: .buffered, defer: false)
            second.title = "ScreenCommander Input Fixture 2"
            second.isReleasedWhenClosed = false
            second.appearance = NSAppearance(named: .darkAqua)
            second.backgroundColor = NSColor(white: 0.16, alpha: 1)
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            second.contentView = root
            let field = NSTextField(frame: NSRect(x: 16, y: 150, width: 228, height: 24))
            field.placeholderString = "Second field"
            field.setAccessibilityLabel("Second field")
            field.delegate = self
            root.addSubview(field)
            let button = NSButton(frame: NSRect(x: 16, y: 100, width: 160, height: 32))
            button.title = "Second button"
            button.setAccessibilityLabel("Second button")
            button.target = self
            button.action = #selector(secondPressed)
            root.addSubview(button)
            // Blocks the main thread for 7 seconds, longer than the 6 second
            // accessibility timeout, so an AXPress on it reports cannotComplete
            // although the press runs.
            let slow = NSButton(frame: NSRect(x: 16, y: 50, width: 160, height: 32))
            slow.title = "Slow button"
            slow.setAccessibilityLabel("Slow button")
            slow.target = self
            slow.action = #selector(slowPressed)
            root.addSubview(slow)
            secondWindow = second
            secondField = field
            if flags.contains("--front") {
                second.orderFrontRegardless()
            } else {
                second.order(.above, relativeTo: window.windowNumber)
            }
            second.makeFirstResponder(field)
        }

        if flags.contains("--panel") {
            let size = NSSize(width: 200, height: 100)
            let panelFrame = NSRect(x: frame.minX + 200, y: frame.minY + 60, width: size.width, height: size.height)
            let inspector = NSPanel(contentRect: panelFrame, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            inspector.title = "Fixture Inspector"
            inspector.isFloatingPanel = true
            inspector.hidesOnDeactivate = false
            inspector.becomesKeyOnlyIfNeeded = true
            inspector.isReleasedWhenClosed = false
            inspector.appearance = NSAppearance(named: .darkAqua)
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            inspector.contentView = root
            let button = NSButton(frame: NSRect(x: 20, y: 34, width: 160, height: 32))
            button.title = "Panel button"
            button.setAccessibilityLabel("Panel button")
            button.target = self
            button.action = #selector(panelPressed)
            root.addSubview(button)
            panel = inspector
            inspector.orderFrontRegardless()
        }

        for observed in [secondWindow, panel].compactMap({ $0 }) {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(forName: name, object: observed, queue: .main) { [weak self] note in
                    self?.write(["kind": note.name.rawValue, "window": observed.windowNumber])
                }
            }
        }
    }

    @objc private func secondPressed(_ sender: NSButton) {
        write(["kind": "secondButtonPressed"])
    }

    @objc private func slowPressed(_ sender: NSButton) {
        write(["kind": "slowButtonPressed"])
        Thread.sleep(forTimeInterval: 7)
        write(["kind": "slowButtonDone"])
    }

    @objc private func panelPressed(_ sender: NSButton) {
        write(["kind": "panelButtonPressed"])
    }

    @objc private func popupChosen(_ sender: NSMenuItem) {
        write(["kind": "popupAction", "item": sender.title])
    }

    private func record(_ event: NSEvent) {
        var entry: [String: Any] = [
            "kind": "event",
            "type": String(describing: event.type),
            "windowNumber": event.windowNumber,
            "locationInWindow": ["x": event.locationInWindow.x, "y": event.locationInWindow.y],
            "modifierFlags": event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
        ]
        switch event.type {
        case .keyDown, .keyUp:
            entry["keyCode"] = Int(event.keyCode)
            entry["characters"] = event.characters ?? ""
        case .scrollWheel:
            entry["scrollingDeltaY"] = event.scrollingDeltaY
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            entry["clickCount"] = event.clickCount
        default:
            break
        }
        write(entry)
    }

    private func pollCommands() {
        guard let data = FileManager.default.contents(atPath: commandPath), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        FileManager.default.createFile(atPath: commandPath, contents: nil)
        for line in text.split(separator: "\n") {
            run(command: line.split(separator: " ").map(String.init))
        }
    }

    private func run(command: [String]) {
        guard let name = command.first else {
            return
        }
        let numbers = command.dropFirst().compactMap(Double.init)
        switch name {
        case "front": window.orderFrontRegardless()
        case "back": window.orderBack(nil)
        case "move" where numbers.count == 2:
            window.setFrameOrigin(NSPoint(x: window.frame.minX + numbers[0], y: window.frame.minY - numbers[1]))
        case "glide" where numbers.count == 3:
            glideTimer?.invalidate()
            let start = window.frame.origin
            let began = Date()
            let duration = max(numbers[2], 0.05)
            let (dx, dy) = (numbers[0], numbers[1])
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { return }
                let progress = min(Date().timeIntervalSince(began) / duration, 1)
                self.window.setFrameOrigin(NSPoint(x: start.x + dx * progress, y: start.y - dy * progress))
                if progress >= 1 {
                    timer.invalidate()
                    self.write(["kind": "glideDone"])
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            glideTimer = timer
        case "minimize": window.miniaturize(nil)
        case "deminimize": window.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhideWithoutActivation()
        case "fullscreen": window.toggleFullScreen(nil)
        case "activate": NSApp.activate(ignoringOtherApps: true)
        case "quit": NSApp.terminate(nil)
        case "front2": secondWindow?.orderFrontRegardless()
        case "back2": secondWindow?.orderBack(nil)
        case "move2" where numbers.count == 2:
            if let second = secondWindow {
                second.setFrameOrigin(NSPoint(x: second.frame.minX + numbers[0], y: second.frame.minY - numbers[1]))
            }
        case "key1": window.makeKey()
        case "key2": secondWindow?.makeKey()
        case "popup":
            // Asynchronously, so the command timer is not blocked while the menu tracks.
            DispatchQueue.main.async { [weak self] in
                guard let self, let menu = self.popupMenu, let content = self.window.contentView else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: content.bounds.midX, y: content.bounds.midY), in: content)
                self.write(["kind": "popupClosed"])
            }
        default: break
        }
        let topLeftY = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
        write([
            "kind": "command",
            "command": command.joined(separator: " "),
            "frameTopLeft": ["x": window.frame.minX, "y": topLeftY, "w": window.frame.width, "h": window.frame.height],
        ])
    }

    @objc func fixtureAction(_ sender: Any?) {
        write(["kind": "menuAction", "item": "Fixture Action"])
    }

    @objc func fixtureDisabled(_ sender: Any?) {
        write(["kind": "menuAction", "item": "Fixture Disabled"])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(fixtureDisabled(_:))
    }

    @objc private func pressed(_ sender: NSButton) {
        pressCount += 1
        write(["kind": "buttonPressed", "count": pressCount])
    }

    @objc private func scrolled(_ notification: Notification) {
        write(["kind": "scrolled", "originY": scrollView.contentView.bounds.origin.y])
    }

    func controlTextDidChange(_ notification: Notification) {
        let field = notification.object as? NSTextField
        let name = field === secondField ? "second" : "first"
        write(["kind": "textChanged", "field": name, "value": field?.stringValue ?? textField.stringValue])
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === notesView else { return }
        write(["kind": "notesChanged", "value": notesView.string])
    }

    private func write(_ entry: [String: Any]) {
        var entry = entry
        entry["ts"] = Date().timeIntervalSince1970
        entry["appActive"] = NSApp.isActive
        entry["windowIsKey"] = window?.isKeyWindow ?? false
        entry["keyWindow"] = NSApp.keyWindow != nil
        entry["keyWindowNumber"] = NSApp.keyWindow?.windowNumber ?? 0
        entry["mainWindow"] = NSApp.mainWindow != nil
        entry["frontmost"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        log.write(data)
        log.write(Data("\n".utf8))
    }
}

/// Only a window's delegate implements the chain action, so it runs only when AppKit
/// sent the nil-targeted action through a key or main window's responder chain.
final class FixtureWindowDelegate: NSObject, NSWindowDelegate {
    var log: (([String: Any]) -> Void)?

    @objc func fixtureChainAction(_ sender: Any?) {
        log?(["kind": "chainAction", "item": "Fixture Chain Action"])
    }
}

/// Handles cmd+j itself, the way an app's custom view handles a shortcut that has
/// no menu item.
final class KeyEquivalentView: NSView {
    var log: (([String: Any]) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers == "j" {
            log?(["kind": "viewKeyEquivalent", "characters": "j"])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Four solid dark quadrants in exact sRGB, each channel 0 or 0x40: dark red, dark
/// green, dark blue, dark yellow, clockwise from the top-left. Drawn from the
/// current bounds, so it survives resizing and full screen.
final class PatternView: NSView {
    /// 0x40 of 0xFF: dark, and still far enough from 0 to tell the channels apart.
    static let level: CGFloat = 64.0 / 255.0

    override func draw(_ dirtyRect: NSRect) {
        let half = NSSize(width: bounds.width / 2, height: bounds.height / 2)
        let quadrants: [(NSPoint, NSColor)] = [
            (NSPoint(x: 0, y: half.height), NSColor(srgbRed: Self.level, green: 0, blue: 0, alpha: 1)),
            (NSPoint(x: half.width, y: half.height), NSColor(srgbRed: 0, green: Self.level, blue: 0, alpha: 1)),
            (NSPoint(x: half.width, y: 0), NSColor(srgbRed: 0, green: 0, blue: Self.level, alpha: 1)),
            (NSPoint(x: 0, y: 0), NSColor(srgbRed: Self.level, green: Self.level, blue: 0, alpha: 1)),
        ]
        for (origin, color) in quadrants {
            color.setFill()
            NSRect(origin: origin, size: half).fill()
        }
    }
}

let app = NSApplication.shared
let fixture = InputFixture()
app.delegate = fixture
app.run()
