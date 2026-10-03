import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

/// How a synthesized input was (or should be) delivered, in ladder order.
///
/// - `ax`: `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` — coordinate-free,
///   works on background apps, never touches the real cursor.
/// - `window`: CGEvents posted with `CGEventPostToPid`, mouse events stamped with the
///   target window and a window-local location. The user's cursor and frontmost app
///   stay put. Some apps ignore posted events while unfocused; posting success is the
///   tier's contract, effect detection is the caller's job.
/// - `focusAssisted`: focus-without-raise records to the target process, then the
///   `window` events (keyboard through authenticated `SLEventPostToPid` for
///   Chromium/Electron).
/// - `global`: CGEvents posted to `.cghidEventTap` with app activation — moves the
///   cursor. Only with `--foreground`.
///
/// `pid` is accepted on input as the pre-1.0 name of `window`.
enum InputDeliveryMethod: String, Codable, Sendable, ExpressibleByArgument, Equatable, CaseIterable {
    case ax
    case window
    case focusAssisted
    case global

    init?(argument: String) {
        self.init(parsing: argument)
    }

    init?(parsing raw: String) {
        if raw == "pid" {
            self = .window
            return
        }
        self.init(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = InputDeliveryMethod(parsing: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown delivery method '\(raw)'; use ax, window, focusAssisted, or global."
            )
        }
        self = value
    }

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }
}

/// Coordinate-free AX actuation, injected into the engine so tests can fake it
/// without a live Accessibility grant.
protocol AXActionPerforming {
    /// Performs a named AX action (`AXPress`, `AXShowMenu`, `AXConfirm`,
    /// `AXIncrement`, `AXDecrement`) on a live element.
    func perform(action: String, on element: AXElement) throws

    /// Performs a named AX action and returns the app's answer as is, so the caller
    /// can tell a refusal from an outcome it cannot know (see `AXActionOutcome`).
    func attempt(action: String, on element: AXElement) -> AXError

    /// Brings one of the app's windows to the front of the app and makes it main
    /// (`AXRaise`, `AXMain`). Used only for foreground delivery, after activation.
    func raiseWindow(pid: pid_t, windowID: CGWindowID) throws

    /// Writes the element's `AXValue` attribute directly (text fields, sliders, ...).
    func setValue(_ value: String, on element: AXElement) throws

    /// Focuses the element (`AXFocused = true`) — used before falling back to the
    /// keyboard path so keystrokes land in the intended field.
    func focus(on element: AXElement) throws

    /// Re-reads the element's `AXValue` as a string, for post-delivery verification.
    func readValue(of element: AXElement) -> String?

    /// Writes `AXSelectedTextRange` (UTF-16 offsets).
    func setSelectedTextRange(_ range: AXTextRange, on element: AXElement) throws

    /// Reads `AXSelectedTextRange`, or nil when the element has none.
    func readSelectedTextRange(of element: AXElement) -> AXTextRange?

    /// Reads `AXSelectedText`, or nil when the element has none.
    func readSelectedText(of element: AXElement) -> String?

    /// Writes `AXSelectedText`: the text replaces the selection, or is inserted at
    /// the caret when nothing is selected.
    func setSelectedText(_ text: String, on element: AXElement) throws

    /// Whether the element reports `attribute` as settable.
    func isSettable(_ attribute: String, on element: AXElement) -> Bool

    /// True for a secure text field, whose value must never be read back.
    func isSecureText(_ element: AXElement) -> Bool

    /// The app's focused UI element when it is a text element (a field, text area,
    /// combo box, or anything with a settable `AXSelectedText`). With `windowID`,
    /// only an element inside that window counts. Nil when there is none.
    func focusedTextElement(pid: pid_t, windowID: CGWindowID?) -> AXElement?

    /// Scrolls the element, or the scroll area around it, by whole pages using AX
    /// alone: a page action the element lists, the scroll bar's page buttons, or a
    /// scroll-bar value write. Throws `elementNotActionable` when none applies.
    func scrollByPage(_ element: AXElement, direction: ScrollDirection, pages: Int) throws -> AXScrollOutcome

    /// The scroll bar position (0...1) on the direction's axis for the scroll area
    /// that contains the element, when AX exposes one.
    func scrollPosition(of element: AXElement, direction: ScrollDirection) -> Double?
}

/// A text range in UTF-16 code units, the unit `AXSelectedTextRange` uses.
struct AXTextRange: Codable, Sendable, Equatable {
    var location: Int
    var length: Int
}

enum ScrollDirection: String, Codable, Sendable, CaseIterable, ExpressibleByArgument {
    case up
    case down
    case left
    case right

    var isVertical: Bool {
        self == .up || self == .down
    }

    /// The page action some scroll areas list, e.g. `AXScrollDownByPage`.
    var pageActionName: String {
        switch self {
        case .up: return "AXScrollUpByPage"
        case .down: return "AXScrollDownByPage"
        case .left: return "AXScrollLeftByPage"
        case .right: return "AXScrollRightByPage"
        }
    }

    /// Scroll-bar page buttons: increment moves toward the end (down/right).
    var pageButtonSubrole: String {
        self == .down || self == .right ? "AXIncrementPage" : "AXDecrementPage"
    }

    /// Down and right move toward the end of the content (scroll bar value grows).
    var isTowardEnd: Bool {
        self == .down || self == .right
    }
}

/// What an AX page scroll did.
struct AXScrollOutcome: Equatable, Sendable {
    /// e.g. `AXScrollDownByPage`, `AXIncrementPage`, or `AXValue`.
    var method: String
    /// Scroll bar position before and after, when readable.
    var before: Double?
    var after: Double?
}

/// A page sequence started scrolling before a later action failed. Delivery
/// must stop here: retrying the requested page count would replay completed pages.
struct AXPartialScrollError: Error {
    let completedPages: Int
    let underlyingError: Error
}

/// What an AX action's answer says about whether it ran.
enum AXActionOutcome: Equatable {
    case performed
    /// The app refused the action before running it (unsupported, not
    /// implemented, accessibility off), so another route can still be tried.
    case refused
    /// The element is gone, so the UI changed and its old position means nothing.
    case elementGone
    /// The app did not confirm (cannot complete, a timeout, a generic failure). The
    /// action may have run, so it must not be tried again another way.
    case unconfirmed

    init(_ error: AXError) {
        switch error {
        case .success:
            self = .performed
        case .invalidUIElement:
            self = .elementGone
        default:
            self = AXPriming.mayHaveApplied(error) ? .unconfirmed : .refused
        }
    }
}

/// Production `AXActionPerforming` backed by live `AXUIElement` calls.
final class AXActions: AXActionPerforming {
    func perform(action: String, on element: AXElement) throws {
        let error = AXUIElementPerformAction(element.raw, action as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "AX action '\(action)' failed (\(Self.describe(error)))."
            )
        }
    }

    func attempt(action: String, on element: AXElement) -> AXError {
        AXUIElementPerformAction(element.raw, action as CFString)
    }

    func raiseWindow(pid: pid_t, windowID: CGWindowID) throws {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(seconds: 0.5)
        guard let window = app.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCommanderError.elementNotActionable("Accessibility lists no window \(windowID) for pid \(pid) to raise.")
        }
        let error = AXUIElementPerformAction(window.raw, kAXRaiseAction as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable("Raising window \(windowID) failed (\(Self.describe(error))).")
        }
        _ = window.setAttribute(kAXMainAttribute, value: kCFBooleanTrue)
    }

    func setValue(_ value: String, on element: AXElement) throws {
        let error = element.setAttribute(kAXValueAttribute, value: value as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXValue failed (\(Self.describe(error)))."
            )
        }
    }

    func focus(on element: AXElement) throws {
        let error = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXFocused failed (\(Self.describe(error)))."
            )
        }
    }

    func readValue(of element: AXElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.raw, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func setSelectedTextRange(_ range: AXTextRange, on element: AXElement) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            throw ScreenCommanderError.elementNotActionable("Could not build an AXValue for the text range.")
        }
        let error = element.setAttribute(kAXSelectedTextRangeAttribute, value: value)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXSelectedTextRange failed (\(Self.describe(error)))."
            )
        }
    }

    func readSelectedTextRange(of element: AXElement) -> AXTextRange? {
        guard let ref = element.copyAttribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else {
            return nil
        }
        return AXTextRange(location: range.location, length: range.length)
    }

    func readSelectedText(of element: AXElement) -> String? {
        element.copyAttribute(kAXSelectedTextAttribute).flatMap(AXElement.coerceToString)
    }

    func setSelectedText(_ text: String, on element: AXElement) throws {
        let error = element.setAttribute(kAXSelectedTextAttribute, value: text as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXSelectedText failed (\(Self.describe(error)))."
            )
        }
    }

    func isSettable(_ attribute: String, on element: AXElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element.raw, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func isSecureText(_ element: AXElement) -> Bool {
        (element.copyAttribute(kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Roles that hold editable text.
    static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
    ]

    func focusedTextElement(pid: pid_t, windowID: CGWindowID?) -> AXElement? {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(seconds: 0.5)
        // Chromium and Electron build their tree only on request. The attribute is
        // side-effect free and other apps refuse it.
        _ = app.setAttribute(AXPriming.manualAccessibility, value: kCFBooleanTrue)
        guard let ref = app.copyAttribute(kAXFocusedUIElementAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = AXElement(raw: ref as! AXUIElement)
        focused.setMessagingTimeout(seconds: 0.5)
        let role = focused.copyAttribute(kAXRoleAttribute) as? String ?? ""
        guard Self.textRoles.contains(role) || isSettable(kAXSelectedTextAttribute, on: focused) else {
            return nil
        }
        if let windowID {
            guard let windowRef = focused.copyAttribute(kAXWindowAttribute),
                  CFGetTypeID(windowRef) == AXUIElementGetTypeID(),
                  let mapped = PrivateAPI.axGetWindow(windowRef as! AXUIElement),
                  mapped.error == .success, mapped.windowID == windowID else {
                return nil
            }
        }
        return focused
    }

    func scrollByPage(_ element: AXElement, direction: ScrollDirection, pages: Int) throws -> AXScrollOutcome {
        let chain = Self.ancestorChain(of: element)

        // 1. A page action listed by the element or an ancestor up to its window.
        // NSScrollView lists these but can refuse them (attribute unsupported), so a
        // refused first page moves on to the scroll bar.
        for candidate in chain where candidate.actionNames.contains(direction.pageActionName) {
            let before = scrollPosition(of: element, direction: direction)
            do {
                try Self.performPages(count: pages) {
                    try perform(action: direction.pageActionName, on: candidate)
                }
            } catch let error as AXPartialScrollError {
                throw error
            } catch {
                break
            }
            let after = Self.settledValue(from: before) { scrollPosition(of: element, direction: direction) }
            return AXScrollOutcome(method: direction.pageActionName, before: before, after: after)
        }

        guard let area = Self.scrollArea(around: element, chain: chain),
              let bar = Self.scrollBar(of: area, vertical: direction.isVertical) else {
            throw ScreenCommanderError.elementNotActionable(
                "No AX scroll action or scroll bar near the element; falls through to wheel events."
            )
        }
        let before = Self.numericValue(of: bar)

        // 2. The scroll bar's page button (present with legacy scrollers).
        if let button = bar.children.first(where: {
            $0.subrole == direction.pageButtonSubrole && $0.actionNames.contains(kAXPressAction)
        }) {
            try Self.performPages(count: pages) {
                try perform(action: kAXPressAction, on: button)
            }
            let after = Self.settledValue(from: before) { Self.numericValue(of: bar) }
            return AXScrollOutcome(method: direction.pageButtonSubrole, before: before, after: after)
        }

        // 3. Write the scroll bar's value, one visible page per page.
        guard let current = before,
              let visible = area.frame.map({ direction.isVertical ? $0.height : $0.width }), visible > 0,
              let content = Self.documentExtent(of: area, vertical: direction.isVertical), content > visible else {
            throw ScreenCommanderError.elementNotActionable(
                "The scroll bar exposes no page buttons or settable value; falls through to wheel events."
            )
        }
        let step = Double(visible) / Double(content - visible) * Double(pages)
        let target = min(1, max(0, direction.isTowardEnd ? current + step : current - step))
        let error = bar.setAttribute(kAXValueAttribute, value: NSNumber(value: target))
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting the scroll bar AXValue failed (\(Self.describe(error))); falls through to wheel events."
            )
        }
        return AXScrollOutcome(method: "AXValue", before: before, after: Self.numericValue(of: bar))
    }

    /// Keep first-page failures eligible for fallback, but preserve progress
    /// when a later page fails so callers cannot replay the entire sequence.
    static func performPages(count: Int, action: () throws -> Void) throws {
        for completed in 0..<count {
            do {
                try action()
            } catch {
                guard completed > 0 else { throw error }
                throw AXPartialScrollError(completedPages: completed, underlyingError: error)
            }
        }
    }

    func scrollPosition(of element: AXElement, direction: ScrollDirection) -> Double? {
        let chain = Self.ancestorChain(of: element)
        guard let area = Self.scrollArea(around: element, chain: chain),
              let bar = Self.scrollBar(of: area, vertical: direction.isVertical) else {
            return nil
        }
        return Self.numericValue(of: bar)
    }

    /// Page scrolls animate, so the scroll bar reaches its new value a little later.
    /// Polls for up to about half a second and returns the last value read.
    private static func settledValue(from before: Double?, read: () -> Double?) -> Double? {
        var value = read()
        for _ in 0..<12 where value == before {
            usleep(40_000)
            value = read()
        }
        return value
    }

    /// The element and its ancestors up to (not including) its window.
    private static func ancestorChain(of element: AXElement) -> [AXElement] {
        var chain = [element]
        var current = element
        for _ in 0..<12 {
            guard let parent = current.parent else { break }
            let role = parent.role
            if role == kAXWindowRole as String || role == kAXApplicationRole as String {
                break
            }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The nearest `AXScrollArea` among the element and its ancestors, else a direct child.
    private static func scrollArea(around element: AXElement, chain: [AXElement]) -> AXElement? {
        if let area = chain.first(where: { $0.role == kAXScrollAreaRole as String }) {
            return area
        }
        return element.children.first { $0.role == kAXScrollAreaRole as String }
    }

    private static func scrollBar(of area: AXElement, vertical: Bool) -> AXElement? {
        let name = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
        guard let ref = area.copyAttribute(name), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return AXElement(raw: ref as! AXUIElement)
    }

    private static func numericValue(of element: AXElement) -> Double? {
        (element.copyAttribute(kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    /// Height (or width) of the scroll area's document: its largest non-scroll-bar child.
    private static func documentExtent(of area: AXElement, vertical: Bool) -> CGFloat? {
        area.children
            .filter { $0.role != kAXScrollBarRole as String }
            .compactMap { $0.frame.map { vertical ? $0.height : $0.width } }
            .max()
    }

    /// A short stable name for an AX error, as results report it.
    static func errorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notImplemented: return "notImplemented"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        default: return "axError\(error.rawValue)"
        }
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .actionUnsupported: return "action unsupported"
        case .attributeUnsupported: return "attribute unsupported"
        case .cannotComplete: return "cannot complete — app may be busy or unresponsive"
        case .invalidUIElement: return "invalid element — the UI changed; re-read with 'elements'"
        case .notImplemented: return "not implemented by the app"
        case .apiDisabled: return "accessibility API disabled"
        case .failure: return "failure"
        default: return "AXError \(error.rawValue)"
        }
    }
}

/// Pure element matching for `--element "<title/label substring>"` (+ optional `--role`).
/// Matching is case-insensitive over `title`, `description`, and `value`. The best
/// match tier must be unique; ambiguous substring matches fail instead of silently
/// selecting tree order.
enum AXElementMatchResult {
    case found(AXElementRecord)
    case ambiguous([AXElementRecord])
}

enum AXElementMatcher {
    static func resolve(records: [AXElementRecord], query: String, role: String?) -> AXElementMatchResult? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }

        let roleFiltered = records.filter { roleMatches($0.role, filter: role) }
        let tiers: [[AXElementRecord]] = [
            roleFiltered.filter { $0.title?.lowercased() == needle },
            roleFiltered.filter { nonTitleText(of: $0).contains(needle) },
            roleFiltered.filter { $0.title?.lowercased().contains(needle) == true },
            roleFiltered.filter { nonTitleText(of: $0).contains { $0.contains(needle) } },
        ]

        guard let best = tiers.first(where: { !$0.isEmpty }) else { return nil }
        guard best.count == 1, let match = best.first else { return .ambiguous(best) }
        return .found(match)
    }

    static func match(records: [AXElementRecord], query: String, role: String?) -> AXElementRecord? {
        switch resolve(records: records, query: query, role: role) {
        case .found(let record):
            return record
        case .ambiguous, nil:
            return nil
        }
    }

    /// "button" and "AXButton" both match `AXButton`, mirroring the tree walker's
    /// role-filter normalization.
    static func roleMatches(_ recordRole: String, filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        let actual = recordRole.lowercased()
        let wanted = filter.lowercased()
        return actual == wanted || actual == "ax" + wanted
    }

    private static func nonTitleText(of record: AXElementRecord) -> [String] {
        [record.description, record.value]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
    }
}
