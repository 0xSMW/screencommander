import AppKit
import CoreGraphics
import Foundation
import Carbon.HIToolbox

protocol KeyboardControlling {
    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination) throws
    func typeByPasting(text: String, destination: InputEventDestination) throws
    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination, beforePosting: () throws -> Void) throws
    func typeByPasting(text: String, destination: InputEventDestination, beforePosting: () throws -> Void) throws
    func press(chord: ParsedKeyChord, destination: InputEventDestination) throws
    /// Media and system keys are system-defined events with no target process; they
    /// only exist on the global path.
    func pressSystemKey(_ key: SystemKey) throws
    func run(sequence: KeySequence, destination: InputEventDestination) throws
    /// Runs `body` between the destination's `prepare` and `finish`, so work that is
    /// not a key event (an AX menu press) happens while `focusAssisted` holds the
    /// target's window key.
    func withPrepared(_ destination: InputEventDestination, _ body: () throws -> Void) throws
}

extension KeyboardControlling {
    // Compatibility for controllers without destination preparation. Controllers
    // that prepare focus must override these and run the callback after preparation.
    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        try beforePosting()
        try type(text: text, delayMilliseconds: delayMilliseconds, destination: destination)
    }

    func typeByPasting(text: String, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        try beforePosting()
        try typeByPasting(text: text, destination: destination)
    }

    func withPrepared(_ destination: InputEventDestination, _ body: () throws -> Void) throws {
        try body()
    }
}

/// Builds keyboard events and hands them to an `InputEventPosting` backend.
///
/// Events come from a private-state source and every event's flags are set
/// explicitly: modifiers held by the user never leak in, and modifiers held by a
/// chord or a `keys` sequence are carried on each event the target receives.
final class KeyboardController: KeyboardControlling {
    private static let pasteboardLock = NSLock()

    private let poster: InputEventPosting
    private let pasteboard: PasteboardAccess
    private let enterKeyDownHoldMicroseconds: useconds_t = 20_000
    private let pidKeyGapMicroseconds: useconds_t = 8_000
    /// How long the pasted text stays on the pasteboard after cmd+v is posted.
    private let pasteboardRestoreDelayMicroseconds: useconds_t
    private let systemDownState = Int(0xA)
    private let systemUpState = Int(0xB)
    private let systemAuxControlSubtype = Int16(0x08)

    init(
        poster: InputEventPosting = LiveInputEventPoster(),
        pasteboard: PasteboardAccess = SystemPasteboard(),
        pasteboardRestoreDelayMicroseconds: useconds_t = 500_000
    ) {
        self.poster = poster
        self.pasteboard = pasteboard
        self.pasteboardRestoreDelayMicroseconds = pasteboardRestoreDelayMicroseconds
    }

    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination) throws {
        try type(text: text, delayMilliseconds: delayMilliseconds, destination: destination, beforePosting: {})
    }

    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        let source = try makeEventSource()
        try poster.prepare(destination)
        defer { poster.finish(destination) }

        try beforePosting()
        let delay = max(0, delayMilliseconds ?? 0)

        for character in text {
            try postUnicodeCharacter(String(character), source: source, destination: destination)
            SleepTimer.sleep(milliseconds: delay)
        }
    }

    func typeByPasting(text: String, destination: InputEventDestination) throws {
        try typeByPasting(text: text, destination: destination, beforePosting: {})
    }

    func typeByPasting(text: String, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        Self.pasteboardLock.lock()
        defer { Self.pasteboardLock.unlock() }

        let delay = pasteboardRestoreDelayMicroseconds
        try PasteboardSwap.withTemporaryString(text, on: pasteboard, wait: { usleep(delay) }) {
            try press(chord: try KeyCodes.parseChord("cmd+v"), destination: destination, beforePosting: beforePosting)
        }
    }

    func press(chord: ParsedKeyChord, destination: InputEventDestination) throws {
        try press(chord: chord, destination: destination, beforePosting: {})
    }

    private func press(chord: ParsedKeyChord, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        let source = try makeEventSource()

        if case .system(let systemKey, _) = chord.key {
            if !chord.modifiers.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system keys.")
            }
            try requireGlobal(destination, for: chord.normalized)
            try pressSystemKey(systemKey)
            return
        }
        if let alias = chord.systemShortcut, destination != .global {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemShortcutRefusal(alias))
        }

        try poster.prepare(destination)
        defer { poster.finish(destination) }
        try beforePosting()
        try runModifiersForStep(flags: chord.flags, held: [], source: source, pressed: true, destination: destination)

        try postKeyboardEvent(
            keyCode: chord.key.keyboardCode,
            keyDown: true,
            flags: chord.flags,
            source: source,
            destination: destination
        )

        if chord.key.keyboardCode == CGKeyCode(kVK_Return) {
            usleep(enterKeyDownHoldMicroseconds)
        } else if destination != .global {
            usleep(pidKeyGapMicroseconds)
        }

        try postKeyboardEvent(
            keyCode: chord.key.keyboardCode,
            keyDown: false,
            flags: chord.flags,
            source: source,
            destination: destination
        )

        try runModifiersForStep(flags: chord.flags, held: [], source: source, pressed: false, destination: destination)
    }

    func withPrepared(_ destination: InputEventDestination, _ body: () throws -> Void) throws {
        try poster.prepare(destination)
        defer { poster.finish(destination) }
        try body()
    }

    func pressSystemKey(_ key: SystemKey) throws {
        try postSystemKeyEvent(systemCode: key.nxKeyCode, keyDown: true)
        usleep(enterKeyDownHoldMicroseconds)
        try postSystemKeyEvent(systemCode: key.nxKeyCode, keyDown: false)
    }

    func run(sequence: KeySequence, destination: InputEventDestination) throws {
        let source = try makeEventSource()

        if destination != .global {
            if let alias = sequence.systemShortcuts.first {
                throw ScreenCommanderError.backgroundDeliveryUnavailable(KeyCodes.systemShortcutRefusal(alias))
            }
            for step in sequence.steps {
                switch step {
                case .keyDown(.system(_, let token), _), .keyUp(.system(_, let token), _), .press(.system(_, let token), _):
                    try requireGlobal(destination, for: token)
                default:
                    break
                }
            }
        }
        try poster.prepare(destination)
        defer { poster.finish(destination) }

        // Modifiers held by earlier `down:` steps, carried on every later event.
        var held = CGEventFlags()

        for step in sequence.steps {
            switch step {
            case .keyDown(let key, let flags):
                try handleStepKeyDown(key: key, flags: flags, held: &held, source: source, destination: destination)
            case .keyUp(let key, let flags):
                try handleStepKeyUp(key: key, flags: flags, held: &held, source: source, destination: destination)
            case .press(let key, let flags):
                switch key {
                case .keyboard:
                    try runModifiersForStep(flags: flags, held: held, source: source, pressed: true, destination: destination)
                    try postResolvedKey(key: key, keyDown: true, flags: held.union(flags), source: source, destination: destination)
                    try postResolvedKey(key: key, keyDown: false, flags: held.union(flags), source: source, destination: destination)
                    try runModifiersForStep(flags: flags, held: held, source: source, pressed: false, destination: destination)
                case .system(let systemKey, _):
                    if !flags.isEmpty {
                        throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
                    }
                    try pressSystemKey(systemKey)
                }
            case .sleep(let milliseconds):
                SleepTimer.sleep(milliseconds: milliseconds)
            }
        }
    }

    private func requireGlobal(_ destination: InputEventDestination, for token: String) throws {
        guard destination == .global else {
            throw ScreenCommanderError.backgroundDeliveryUnavailable(
                "'\(token)' is a system key with no target app; it can only be sent globally."
            )
        }
    }

    private func handleStepKeyDown(
        key: ResolvedKey,
        flags: CGEventFlags,
        held: inout CGEventFlags,
        source: CGEventSource,
        destination: InputEventDestination
    ) throws {
        switch key {
        case .keyboard(let keyCode, _):
            try runModifiersForStep(flags: flags, held: held, source: source, pressed: true, destination: destination)
            if let modifier = Self.modifierFlag(forKeyCode: keyCode) {
                held.insert(modifier)
            }
            try postResolvedKey(key: key, keyDown: true, flags: held.union(flags), source: source, destination: destination)
        case .system(let systemKey, _):
            if !flags.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
            }
            try postSystemKeyEvent(systemCode: systemKey.nxKeyCode, keyDown: true)
        }
    }

    private func handleStepKeyUp(
        key: ResolvedKey,
        flags: CGEventFlags,
        held: inout CGEventFlags,
        source: CGEventSource,
        destination: InputEventDestination
    ) throws {
        switch key {
        case .keyboard(let keyCode, _):
            if let modifier = Self.modifierFlag(forKeyCode: keyCode) {
                held.remove(modifier)
            }
            try postResolvedKey(key: key, keyDown: false, flags: held.union(flags), source: source, destination: destination)
            try runModifiersForStep(flags: flags, held: held, source: source, pressed: false, destination: destination)
        case .system(let systemKey, _):
            if !flags.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
            }
            try postSystemKeyEvent(systemCode: systemKey.nxKeyCode, keyDown: false)
        }
    }

    /// The flag a modifier key sets while it is down, for both left and right keys.
    static func modifierFlag(forKeyCode keyCode: CGKeyCode) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            return .maskCommand
        case kVK_Shift, kVK_RightShift:
            return .maskShift
        case kVK_Option, kVK_RightOption:
            return .maskAlternate
        case kVK_Control, kVK_RightControl:
            return .maskControl
        case kVK_Function:
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    private func postResolvedKey(
        key: ResolvedKey,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource,
        destination: InputEventDestination
    ) throws {
        guard let keyCode = key.keyboardCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post unsupported key type.")
        }

        try postKeyboardEvent(
            keyCode: keyCode,
            keyDown: keyDown,
            flags: flags,
            source: source,
            destination: destination
        )
    }

    /// Posts the chord's modifier keys around the main key. Each modifier event
    /// carries the flags that are down at that moment, the way a real keyboard
    /// reports them: flags grow as modifiers go down and shrink as they come up.
    private func runModifiersForStep(
        flags: CGEventFlags,
        held: CGEventFlags,
        source: CGEventSource,
        pressed: Bool,
        destination: InputEventDestination
    ) throws {
        let modifiers = modifierKeys(from: flags)
        if pressed {
            var current = held
            for modifier in modifiers where !modifier.isFnOnlyFlag {
                current.insert(modifier.flag)
                try postKeyCode(modifier.keyCode, keyDown: true, flags: current, source: source, destination: destination)
            }
        } else {
            var current = held.union(flags)
            for modifier in modifiers.reversed() where !modifier.isFnOnlyFlag {
                current.remove(modifier.flag)
                try postKeyCode(modifier.keyCode, keyDown: false, flags: current.union(held), source: source, destination: destination)
            }
        }
    }

    private func modifierKeys(from flags: CGEventFlags) -> [ModifierKey] {
        ModifierKey.allCases.filter { flags.contains($0.flag) }
    }

    private func postKeyboardEvent(
        keyCode: CGKeyCode?,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource,
        destination: InputEventDestination
    ) throws {
        guard let keyCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post key event without keycode.")
        }

        try postKeyCode(keyCode, keyDown: keyDown, flags: flags, source: source, destination: destination)
    }

    private func postKeyCode(
        _ keyCode: CGKeyCode?,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource,
        destination: InputEventDestination
    ) throws {
        guard let keyCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post key event without keycode.")
        }

        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create key event for keycode \(keyCode).")
        }

        event.flags = flags
        poster.post(event, to: destination, kind: .keyboard)
    }

    private func postSystemKeyEvent(systemCode: Int64, keyDown: Bool) throws {
        let state = keyDown ? systemDownState : systemUpState
        let data1 = Int((systemCode << 16) | (Int64(state) << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: systemAuxControlSubtype,
            data1: data1,
            data2: 0
        ) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not construct system-defined event for system key.")
        }

        guard let cgEvent = event.cgEvent else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not convert system-defined event for system key.")
        }

        poster.post(cgEvent, to: .global, kind: .keyboard)
    }

    /// Line breaks and tabs go out on their own keys, Return and Tab, the way a
    /// keyboard sends them. On key code 0 they would read as the A key to an app that
    /// looks at key codes, which Chromium does. Nil for every other character.
    static func dedicatedKey(for character: Character) -> (keyCode: CGKeyCode, text: String)? {
        switch character {
        case "\n", "\r", "\r\n":
            return (CGKeyCode(kVK_Return), "\r")
        case "\t":
            return (CGKeyCode(kVK_Tab), "\t")
        default:
            return nil
        }
    }

    private func postUnicodeCharacter(_ character: String, source: CGEventSource, destination: InputEventDestination) throws {
        let dedicated = character.count == 1 ? Self.dedicatedKey(for: Character(character)) : nil
        let utf16 = Array((dedicated?.text ?? character).utf16)
        let keyCode = dedicated?.keyCode ?? 0

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create Unicode keyboard events.")
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.flags = []
        keyUp.flags = []

        poster.post(keyDown, to: destination, kind: .keyboard)
        if destination != .global {
            usleep(pidKeyGapMicroseconds)
        }
        poster.post(keyUp, to: destination, kind: .keyboard)
    }

    private func makeEventSource() throws -> CGEventSource {
        guard let source = SyntheticEventSource.make() else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create keyboard event source.")
        }
        return source
    }
}

// MARK: - Pasteboard

/// Every item on a pasteboard, with every type's raw data, so a restore puts back
/// images, files, and rich text as well as plain text.
struct PasteboardSnapshot: Equatable {
    struct Value: Equatable {
        var type: String
        var data: Data
    }

    var items: [[Value]]
}

/// The pasteboard operations paste mode needs. `SystemPasteboard` in production;
/// tests use a fake so they never touch the user's clipboard.
protocol PasteboardAccess: AnyObject {
    /// Increments on every ownership change, including another app's write.
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    /// Clears the pasteboard and writes `text`. Returns the change count the write
    /// produced, or nil when the write failed.
    func replace(withString text: String) -> Int?
    func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardSnapshot.Value(type: type.rawValue, data: $0) }
            }
        })
    }

    func replace(withString text: String) -> Int? {
        let count = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string) ? count : nil
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        let items = snapshot.items.map { values in
            let item = NSPasteboardItem()
            for value in values {
                item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type))
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}

/// Puts text on the pasteboard for the length of one paste, then puts the user's
/// clipboard back.
enum PasteboardSwap {
    /// `wait` runs after `body` succeeds and gives the target time to read the
    /// pasteboard, since posting cmd+v only queues the chord. The prior contents
    /// are restored after `wait`, or right away when the write or `body` fails.
    /// When something else has written to the pasteboard since our write (its
    /// change count moved on), that newer content is left alone.
    static func withTemporaryString(
        _ text: String,
        on pasteboard: PasteboardAccess,
        wait: () -> Void,
        body: () throws -> Void
    ) throws {
        let prior = pasteboard.snapshot()
        let before = pasteboard.changeCount
        guard let written = pasteboard.replace(withString: text) else {
            // A failed write may still have cleared the pasteboard.
            if pasteboard.changeCount != before {
                _ = restoreIfOwned(prior, on: pasteboard, ownedCount: pasteboard.changeCount)
            }
            throw ScreenCommanderError.inputSynthesisFailed("Could not set clipboard text for paste input.")
        }
        do {
            try body()
        } catch {
            _ = restoreIfOwned(prior, on: pasteboard, ownedCount: written)
            throw error
        }
        wait()
        guard restoreIfOwned(prior, on: pasteboard, ownedCount: written) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not restore previous clipboard contents after paste input.")
        }
    }

    /// True when the restore succeeded or was skipped because the pasteboard is no
    /// longer ours.
    private static func restoreIfOwned(_ prior: PasteboardSnapshot, on pasteboard: PasteboardAccess, ownedCount: Int) -> Bool {
        guard pasteboard.changeCount == ownedCount else { return true }
        return pasteboard.restore(prior)
    }
}

private extension ModifierKey {
    var isFnOnlyFlag: Bool {
        self == .fn
    }
}
