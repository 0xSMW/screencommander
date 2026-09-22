import ApplicationServices
import CoreGraphics
import Foundation

/// Private-but-stable HIServices symbol that maps an AX window element to its CGWindowID.
/// Used only for `--window-id` targeting; failures degrade to `nil` (no crash, no throw).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The public headers expose `kAXPositionAttribute`/`kAXSizeAttribute` but not the
/// combined frame attribute, which most apps nevertheless implement.
private let axFrameAttributeName = "AXFrame"

/// Owned by one tree read. A transient child or attribute failure must not make
/// an incomplete tree appear authoritative to snapshot/delta consumers.
final class AXReadDiagnostics {
    private(set) var hadTransientError = false

    func markIncomplete() { hadTransientError = true }

    /// A requested positive child page must arrive in full, including when AX
    /// reports noValue after a preceding count read. Otherwise absence is unknown.
    func validatePage(receivedCount: Int?, requestedCount: Int) {
        if receivedCount != requestedCount { markIncomplete() }
    }

    func record(_ error: AXError) {
        switch error {
        case .cannotComplete, .invalidUIElement, .failure:
            hadTransientError = true
        default:
            break
        }
    }
}

/// Value-typed wrapper over `AXUIElement` with typed, optional-returning accessors.
///
/// Every accessor swallows AX errors and returns `nil` (or an empty collection) instead:
/// a traversal must be able to walk past broken, stale, or permission-limited elements
/// without crashing or aborting.
struct AXElement {
    let raw: AXUIElement
    let diagnostics: AXReadDiagnostics?

    init(raw: AXUIElement, diagnostics: AXReadDiagnostics? = nil) {
        self.raw = raw
        self.diagnostics = diagnostics
    }

    static func application(pid: pid_t, diagnostics: AXReadDiagnostics? = nil) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid), diagnostics: diagnostics)
    }

    static func systemWide() -> AXElement {
        AXElement(raw: AXUIElementCreateSystemWide())
    }

    /// Applies a timeout only to this AX handle; the system-wide timeout is left alone.
    func setMessagingTimeout(seconds: Float) {
        diagnostics?.record(AXUIElementSetMessagingTimeout(raw, seconds))
    }

    // MARK: - Typed accessors

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var axDescription: String? { string(kAXDescriptionAttribute) }
    var help: String? { string(kAXHelpAttribute) }

    /// The element's value coerced to a string (strings, numbers, booleans, URLs,
    /// attributed strings, and AXValue geometry all coerce; anything else is `nil`).
    var value: String? {
        copyAttribute(kAXValueAttribute).flatMap(Self.coerceToString)
    }

    var isEnabled: Bool? { bool(kAXEnabledAttribute) }
    var isFocused: Bool? { bool(kAXFocusedAttribute) }

    /// Element frame in global top-left-origin points. Prefers the combined `AXFrame`
    /// attribute and falls back to `AXPosition` + `AXSize`.
    var frame: CGRect? {
        if let rect = Self.rectValue(copyAttribute(axFrameAttributeName)) {
            return rect
        }
        guard let origin = Self.pointValue(copyAttribute(kAXPositionAttribute)),
              let size = Self.sizeValue(copyAttribute(kAXSizeAttribute)) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    var parent: AXElement? {
        element(copyAttribute(kAXParentAttribute))
    }

    var children: [AXElement] {
        elementArray(copyAttribute(kAXChildrenAttribute))
    }

    func indexedChildren(beforePage: () -> Bool = { true }) -> [(index: Int, element: AXElement)] {
        let count = childCount
        guard count > 0 else { return [] }
        var result: [(index: Int, element: AXElement)] = []
        for start in stride(from: 0, to: count, by: 128) {
            guard beforePage() else { break }
            result.append(contentsOf: childrenPage(start: start, length: min(128, count - start)))
        }
        return result
    }

    /// Count and page AX children without copying a large child array at once.
    /// Transient AX failures do not trigger a second wholesale read.
    var childCount: Int {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(raw, kAXChildrenAttribute as CFString, &count)
        diagnostics?.record(error)
        if error == .success { return max(0, count) }
        if error == .notImplemented || error == .attributeUnsupported {
            return (copyAttribute(kAXChildrenAttribute) as? [AnyObject])?.count ?? 0
        }
        return 0
    }

    func childrenPage(start: Int, length: Int) -> [(index: Int, element: AXElement)] {
        guard start >= 0, length > 0 else { return [] }
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(
            raw, kAXChildrenAttribute as CFString, start, length, &values
        )
        diagnostics?.record(error)
        if error == .illegalArgument { diagnostics?.markIncomplete() }
        if error == .success, let values = values as? [AnyObject] {
            diagnostics?.validatePage(receivedCount: values.count, requestedCount: length)
            return Self.indexedElements(values, startingAt: start, diagnostics: diagnostics)
        }
        guard error == .notImplemented || error == .attributeUnsupported,
              let all = copyAttribute(kAXChildrenAttribute) as? [AnyObject],
              start < all.count else {
            diagnostics?.validatePage(receivedCount: nil, requestedCount: length)
            return []
        }
        let page = Array(all[start..<min(all.count, start + length)])
        diagnostics?.validatePage(receivedCount: page.count, requestedCount: length)
        return Self.indexedElements(page, startingAt: start, diagnostics: diagnostics)
    }

    var windows: [AXElement] {
        elementArray(copyAttribute(kAXWindowsAttribute))
    }

    var focusedWindow: AXElement? {
        element(copyAttribute(kAXFocusedWindowAttribute))
    }

    /// CGWindowID for window elements; `nil` for non-windows or when unavailable.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        let error = _AXUIElementGetWindow(raw, &id)
        diagnostics?.record(error)
        guard error == .success, id != 0 else {
            return nil
        }
        return id
    }

    var actionNames: [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(raw, &names)
        diagnostics?.record(error)
        guard error == .success,
              let names = names as? [String] else {
            return []
        }
        return names
    }

    /// Ranged text extraction (`AXStringForRange`) for reading large documents without
    /// copying the whole value.
    func string(forRange location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            raw,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        diagnostics?.record(error)
        guard error == .success, let result else {
            return nil
        }
        return Self.coerceToString(result)
    }

    // MARK: - Batched reads

    /// Reads several attributes in one IPC round trip. Transient wholesale errors
    /// return nil entries; retrying each attribute would multiply a failing call.
    func attributeValues(_ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            raw,
            names as CFArray,
            AXCopyMultipleAttributeOptions(),
            &values
        )
        diagnostics?.record(error)
        guard error == .success,
              let values = values as? [AnyObject],
              values.count == names.count else {
            if error == .success { diagnostics?.markIncomplete() }
            if error == .notImplemented || error == .attributeUnsupported {
                return names.map { copyAttribute($0) }
            }
            return Array(repeating: nil, count: names.count)
        }

        return values.map { item -> CFTypeRef? in
            let ref = item as CFTypeRef
            if CFGetTypeID(ref) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(item, to: AXValue.self)
                if AXValueGetType(axValue) == .axError {
                    var attributeError = AXError.success
                    if AXValueGetValue(axValue, .axError, &attributeError) {
                        diagnostics?.record(attributeError)
                    }
                    return nil
                }
            }
            return ref
        }
    }

    // MARK: - Raw attribute plumbing

    func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        diagnostics?.record(error)
        guard error == .success else {
            return nil
        }
        return value
    }

    func setAttribute(_ name: String, value: CFTypeRef) -> AXError {
        let error = AXUIElementSetAttributeValue(raw, name as CFString, value)
        diagnostics?.record(error)
        return error
    }

    private func string(_ name: String) -> String? {
        copyAttribute(name).flatMap(Self.coerceToString)
    }

    private func bool(_ name: String) -> Bool? {
        guard let value = copyAttribute(name), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func element(_ ref: CFTypeRef?) -> AXElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return AXElement(raw: ref as! AXUIElement, diagnostics: diagnostics)
    }

    private func elementArray(_ ref: CFTypeRef?) -> [AXElement] {
        guard let ref, let array = ref as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else {
                return nil
            }
            return AXElement(raw: item as! AXUIElement, diagnostics: diagnostics)
        }
    }

    private static func indexedElements(_ values: [AnyObject], startingAt start: Int,
                                        diagnostics: AXReadDiagnostics?) -> [(index: Int, element: AXElement)] {
        values.enumerated().compactMap { offset, item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (index: start + offset,
                    element: AXElement(raw: item as! AXUIElement, diagnostics: diagnostics))
        }
    }

    // MARK: - CF value coercion

    static func coerceToString(_ ref: CFTypeRef) -> String? {
        let typeID = CFGetTypeID(ref)
        if typeID == CFStringGetTypeID() {
            return (ref as! CFString) as String
        }
        if typeID == CFAttributedStringGetTypeID() {
            return CFAttributedStringGetString((ref as! CFAttributedString)) as String
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            return (ref as! NSNumber).stringValue
        }
        if typeID == CFURLGetTypeID() {
            return ((ref as! CFURL) as URL).absoluteString
        }
        if typeID == AXValueGetTypeID() {
            return describeAXValue(ref as! AXValue)
        }
        return nil
    }

    static func rectValue(_ ref: CFTypeRef?) -> CGRect? {
        guard let axValue = axValue(ref, ofType: .cgRect) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func pointValue(_ ref: CFTypeRef?) -> CGPoint? {
        guard let axValue = axValue(ref, ofType: .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func sizeValue(_ ref: CFTypeRef?) -> CGSize? {
        guard let axValue = axValue(ref, ofType: .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ ref: CFTypeRef?, ofType type: AXValueType) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let axValue = ref as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    private static func describeAXValue(_ value: AXValue) -> String? {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
            return "(\(point.x), \(point.y))"
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else { return nil }
            return "\(size.width)x\(size.height)"
        case .cgRect:
            var rect = CGRect.zero
            guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
            return "(\(rect.origin.x), \(rect.origin.y) \(rect.width)x\(rect.height))"
        case .cfRange:
            var range = CFRange(location: 0, length: 0)
            guard AXValueGetValue(value, .cfRange, &range) else { return nil }
            return "[\(range.location), \(range.length)]"
        default:
            return nil
        }
    }
}
