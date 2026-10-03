import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A menu item's keyboard shortcut as Accessibility reports it.
struct MenuShortcut: Equatable, Sendable {
    /// `AXMenuItemCmdChar`, uppercased. AppKit reports letters in upper case and
    /// carries Shift in the modifiers.
    var character: String?
    /// `AXMenuItemCmdVirtualKey`, set for keys that have no character (arrows,
    /// function keys). Used only when `character` is empty.
    var virtualKey: Int?
    /// Command, Shift, Option, and Control, decoded from `AXMenuItemCmdModifiers`.
    var flags: CGEventFlags

    static let chordModifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    /// `AXMenuItemCmdModifiers` uses the Carbon menu modifier bits: Shift 1,
    /// Option 2, Control 4, and 8 for "no Command key". Command is implied otherwise.
    static func flags(fromMenuModifiers modifiers: Int) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers & 8 == 0 { flags.insert(.maskCommand) }
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 4 != 0 { flags.insert(.maskControl) }
        return flags
    }

    /// True when pressing `chord` would trigger this item: the same Command, Shift,
    /// Option, and Control state, and the same key.
    func matches(_ chord: ParsedKeyChord) -> Bool {
        guard case .keyboard(let keyCode, let token) = chord.key,
              chord.flags.intersection(Self.chordModifierMask) == flags else {
            return false
        }
        if let character, !character.isEmpty {
            return Self.menuCharacter(forToken: token) == character
        }
        if let virtualKey, virtualKey >= 0 {
            return virtualKey == Int(keyCode)
        }
        return false
    }

    /// The `AXMenuItemCmdChar` a menu reports for a key token: the character itself
    /// for printable keys, and the AppKit function-key characters for the rest.
    static func menuCharacter(forToken token: String) -> String? {
        if token.count == 1 {
            return token.uppercased()
        }
        let scalar: UInt32?
        switch token {
        case "space": scalar = 0x20
        case "tab": scalar = 0x09
        case "enter", "return": scalar = 0x0D
        case "esc", "escape": scalar = 0x1B
        case "delete": scalar = 0x08
        case "forwarddelete": scalar = 0xF728
        case "up", "uparrow": scalar = 0xF700
        case "down", "downarrow": scalar = 0xF701
        case "left", "leftarrow": scalar = 0xF702
        case "right", "rightarrow": scalar = 0xF703
        case "home": scalar = 0xF729
        case "end": scalar = 0xF72B
        case "pageup", "pgup": scalar = 0xF72C
        case "pagedown", "pgdown": scalar = 0xF72D
        default:
            if token.hasPrefix("f"), let number = Int(token.dropFirst()), (1...20).contains(number) {
                scalar = 0xF704 + UInt32(number - 1)
            } else {
                scalar = nil
            }
        }
        return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}

/// One menu item that has a keyboard shortcut.
struct MenuShortcutItem {
    /// Menu bar title first, item title last, e.g. `["Edit", "Select All"]`.
    var path: [String]
    var shortcut: MenuShortcut
    /// The live item. Nil only in tests.
    var element: AXUIElement?

    /// `Edit > Select All`.
    var pathDescription: String { path.joined(separator: " > ") }
}

/// Finds and presses an app's menu items by keyboard shortcut through its AX menu
/// bar. Injected into the engine so tests never touch a real app's menus.
protocol MenuShortcutResolving: AnyObject {
    /// The app's menu item for `chord`, never one in the Apple menu. Nil when no
    /// menu item uses the chord or the menu bar cannot be read.
    func match(chord: ParsedKeyChord, pid: pid_t) -> MenuShortcutItem?
    /// `AXEnabled` right now. Nil when it cannot be read.
    func isEnabled(_ item: MenuShortcutItem) -> Bool?
    /// `AXPress` on the item. It runs the item's command without opening the menu.
    func press(_ item: MenuShortcutItem) -> AXError
    /// Forgets the cached menu map for `pid`, after a press found a stale element.
    func invalidate(pid: pid_t)
}

/// Reads the menu bar through Accessibility. The map of shortcut items is cached
/// per pid for `cacheTTL` seconds, which matters in `serve`. `AXEnabled` is never
/// cached: it is read at press time.
final class AXMenuShortcuts: MenuShortcutResolving, @unchecked Sendable {
    static let maximumDepth = 6
    static let maximumItems = 4_000
    private static let attributes = [
        kAXRoleAttribute,
        kAXTitleAttribute,
        "AXMenuItemCmdChar",
        "AXMenuItemCmdVirtualKey",
        "AXMenuItemCmdModifiers",
        kAXChildrenAttribute,
    ] as CFArray

    private let cacheTTL: TimeInterval
    private let messagingTimeout: Float
    private let now: () -> Date
    private let lock = NSLock()
    private var cache: [pid_t: (items: [MenuShortcutItem], at: Date)] = [:]

    init(cacheTTL: TimeInterval = 5, messagingTimeout: Float = 0.5, now: @escaping () -> Date = Date.init) {
        self.cacheTTL = cacheTTL
        self.messagingTimeout = messagingTimeout
        self.now = now
    }

    func match(chord: ParsedKeyChord, pid: pid_t) -> MenuShortcutItem? {
        Self.firstMatch(chord: chord, in: items(pid: pid)) { self.isEnabled($0) }
    }

    /// The first matching item in menu order. Menus can hold hidden alternates with
    /// the same shortcut, so an enabled match wins over an earlier disabled one when
    /// `isEnabled` is given.
    static func firstMatch(
        chord: ParsedKeyChord,
        in items: [MenuShortcutItem],
        isEnabled: ((MenuShortcutItem) -> Bool?)? = nil
    ) -> MenuShortcutItem? {
        let matches = items.filter { $0.shortcut.matches(chord) }
        if let isEnabled, matches.count > 1, let enabled = matches.first(where: { isEnabled($0) == true }) {
            return enabled
        }
        return matches.first
    }

    func isEnabled(_ item: MenuShortcutItem) -> Bool? {
        guard let element = item.element else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    func press(_ item: MenuShortcutItem) -> AXError {
        guard let element = item.element else { return .invalidUIElement }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    func invalidate(pid: pid_t) {
        lock.lock()
        cache.removeValue(forKey: pid)
        lock.unlock()
    }

    func items(pid: pid_t) -> [MenuShortcutItem] {
        lock.lock()
        if let cached = cache[pid], now().timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return cached.items
        }
        lock.unlock()

        let items = readItems(pid: pid)
        lock.lock()
        cache[pid] = (items, now())
        lock.unlock()
        return items
    }

    private func readItems(pid: pid_t) -> [MenuShortcutItem] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            return []
        }
        let bar = barValue as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, messagingTimeout)
        var items: [MenuShortcutItem] = []
        // The first menu bar item is the Apple menu, which belongs to the system
        // (Lock Screen, Log Out, Force Quit). It is never searched.
        for barItem in children(of: bar).dropFirst() {
            let title = read(barItem).title
            walk(barItem, path: [title], depth: 1, into: &items)
            if items.count >= Self.maximumItems { break }
        }
        return items
    }

    private struct Node {
        var role: String?
        var title: String
        var shortcut: MenuShortcut?
        var children: [AXUIElement]
    }

    private func walk(_ element: AXUIElement, path: [String], depth: Int, into items: inout [MenuShortcutItem]) {
        guard depth <= Self.maximumDepth else { return }
        for child in read(element).children {
            if items.count >= Self.maximumItems { return }
            let node = read(child)
            switch node.role {
            case kAXMenuRole:
                walk(child, path: path, depth: depth + 1, into: &items)
            case kAXMenuItemRole:
                if let shortcut = node.shortcut, node.children.isEmpty {
                    items.append(MenuShortcutItem(path: path + [node.title], shortcut: shortcut, element: child))
                }
                if !node.children.isEmpty {
                    walk(child, path: path + [node.title], depth: depth + 1, into: &items)
                }
            default:
                break
            }
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        read(element).children
    }

    private func read(_ element: AXUIElement) -> Node {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == 6 else {
            return Node(role: nil, title: "", shortcut: nil, children: [])
        }
        func string(_ index: Int) -> String? { array[index] as? String }
        func int(_ index: Int) -> Int? { (array[index] as? NSNumber)?.intValue }
        let character = string(2)
        let virtualKey = int(3)
        var shortcut: MenuShortcut?
        if (character.map { !$0.isEmpty } ?? false) || virtualKey != nil {
            shortcut = MenuShortcut(
                character: character?.uppercased(),
                virtualKey: virtualKey,
                flags: MenuShortcut.flags(fromMenuModifiers: int(4) ?? 0)
            )
        }
        let children = (array[5] as? [AnyObject])?.compactMap { item -> AXUIElement? in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        } ?? []
        return Node(role: string(0), title: string(1) ?? "", shortcut: shortcut, children: children)
    }
}
