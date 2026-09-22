import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Traversal options for `AccessibilityReading.tree`.
struct AXTreeOptions: Sendable {
    enum Profile: String, Sendable { case full, text }
    /// Restrict traversal to the window with this CGWindowID.
    var windowID: UInt32?
    /// Traverse every window instead of just the focused one.
    var allWindows: Bool
    var maxDepth: Int
    var maxElements: Int
    /// Emit only these roles ("AXButton" and "button" both match).
    var roles: [String]?
    /// Emit only elements whose frame intersects their window's bounds.
    var visibleOnly: Bool
    /// Truncate element values longer than this many characters.
    var maxValueLength: Int
    /// A text read omits action and geometry AX calls.
    var profile: Profile
    /// Optional cap on visited nodes, including filtered containers.
    var maxVisited: Int?
    /// Optional monotonic traversal deadline in milliseconds.
    var timeoutMS: Int?

    init(
        windowID: UInt32? = nil,
        allWindows: Bool = false,
        maxDepth: Int = 40,
        maxElements: Int = 2000,
        roles: [String]? = nil,
        visibleOnly: Bool = false,
        maxValueLength: Int = 200,
        profile: Profile = .full,
        maxVisited: Int? = nil,
        timeoutMS: Int? = nil
    ) {
        self.windowID = windowID
        self.allWindows = allWindows
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.roles = roles
        self.visibleOnly = visibleOnly
        self.maxValueLength = maxValueLength
        self.profile = profile
        self.maxVisited = maxVisited
        self.timeoutMS = timeoutMS
    }
}

/// Result of one tree read.
struct AXTreeResult: Sendable {
    /// Whether Electron/Chromium priming was applied to the app element.
    var axPrimed: Bool
    /// True when traversal stopped at `maxElements`.
    var truncated: Bool
    var elements: [AXElementRecord]
    var visitedCount: Int?
    var partialReason: String?

    init(axPrimed: Bool, truncated: Bool, elements: [AXElementRecord],
         visitedCount: Int? = nil, partialReason: String? = nil) {
        self.axPrimed = axPrimed
        self.truncated = truncated
        self.elements = elements
        self.visitedCount = visitedCount
        self.partialReason = partialReason
    }
}

/// Read-only accessibility surface, injected into the engine so tests can fake it.
protocol AccessibilityReading {
    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult
    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord?
    /// Resolves a dot-joined child-index path (e.g. "0.3.2") to a live element.
    /// Ids are positional and must be resolved fresh — never cached across UI changes.
    func resolve(id: String, app: ResolvedApp) throws -> AXElement
    /// Resolves once and returns both the live handle and its current record.
    func readResolved(id: String, app: ResolvedApp) throws -> (element: AXElement, record: AXElementRecord)
}

extension AccessibilityReading {
    func readResolved(id: String, app: ResolvedApp) throws -> (element: AXElement, record: AXElementRecord) {
        let tree = try tree(app: app, options: AXTreeOptions())
        guard let record = tree.elements.first(where: { $0.id == id }) else {
            throw ScreenCommanderError.elementNotFound(
                "No element with id '\(id)' in '\(app.name)'. Ids are positional and "
                    + "change with the UI — re-read the tree with 'elements --app \(app.name)'."
            )
        }
        return (try resolve(id: id, app: app), record)
    }
}

/// The default `elements` target when `--app` is not given.
enum FrontmostApp {
    static func current() -> ResolvedApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return ResolvedApp(app)
    }
}

/// Production `AccessibilityReading` backed by live `AXUIElement` calls.
final class AXReader: AccessibilityReading {
    /// Attributes fetched per element in one batched IPC round trip.
    private static let fullAttributeNames: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXEnabledAttribute,
        kAXFocusedAttribute,
        "AXFrame",
        kAXPositionAttribute,
        kAXSizeAttribute
    ]
    private static let textAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, kAXEnabledAttribute, kAXFocusedAttribute
    ]

    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult {
        let deadlineNanos = Self.deadlineNanos(timeoutMS: options.timeoutMS)
        let diagnostics = AXReadDiagnostics()
        let appElement = AXElement.application(pid: app.pid, diagnostics: diagnostics)

        if Self.hasExpired(deadlineNanos) { return Self.timedOutTree() }
        prepare(appElement, deadlineNanos: deadlineNanos)

        let priming = prime(appElement, deadlineNanos: deadlineNanos)
        defer { priming.restore() }
        if Self.hasExpired(deadlineNanos) {
            return Self.timedOutTree(axPrimed: priming.axPrimed)
        }

        let roots = try rootElements(appElement: appElement, app: app, options: options,
                                     deadlineNanos: deadlineNanos)
        if Self.hasExpired(deadlineNanos) {
            return Self.timedOutTree(axPrimed: priming.axPrimed)
        }
        let walker = AXTreeWalker(
            maxDepth: options.maxDepth,
            maxElements: options.maxElements,
            roles: options.roles,
            visibleOnly: options.visibleOnly,
            maxVisited: options.maxVisited,
            timeoutMS: options.timeoutMS
        )

        let walk = walker.walk(
            roots: roots,
            childCount: { element in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return element.childCount
            },
            childrenPage: { element, start, length in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return element.childrenPage(start: start, length: length).map { child in
                    self.prepare(child.element, deadlineNanos: deadlineNanos)
                    return (child.index, child.element)
                }
            },
            role: options.roles == nil ? nil : { element in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return element.role
            },
            frame: options.visibleOnly ? { element in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return element.frame
            } : nil,
            record: { element, id in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return self.makeRecord(element: element, id: id,
                                maxValueLength: options.maxValueLength, profile: options.profile,
                                deadlineNanos: deadlineNanos)
            },
            deadlineNanos: deadlineNanos
        )

        let expired = Self.hasExpired(deadlineNanos)
        let partialReason = expired ? "timeout" : (walk.partialReason ?? (diagnostics.hadTransientError ? "ax_error" : nil))
        if partialReason == nil && Self.indicatesUnusableTree(
            visitedCount: walk.visitedCount,
            truncated: walk.truncated,
            maxDepth: options.maxDepth
        ) {
            throw ScreenCommanderError.axTreeUnavailable(
                "App '\(app.name)' (pid \(app.pid)) exposes no usable accessibility tree. "
                    + "The app may still be launching, or may not implement accessibility."
            )
        }

        return AXTreeResult(
            axPrimed: priming.axPrimed,
            truncated: walk.truncated || partialReason != nil,
            elements: walk.records,
            visitedCount: walk.visitedCount,
            partialReason: partialReason
        )
    }

    /// Empty/one-node trees signal an app with no usable AX tree (ax_tree_unavailable),
    /// but only when traversal ended naturally: user-set limits (`--max-elements 1`
    /// truncates after the root; `--max-depth 1` visits only the root of a
    /// single-window app) legitimately stop at one node and must not be treated as
    /// an unusable tree.
    static func indicatesUnusableTree(visitedCount: Int, truncated: Bool, maxDepth: Int) -> Bool {
        visitedCount <= 1 && !truncated && maxDepth > 1
    }

    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord? {
        let systemWide = AXElement.systemWide()
        var ref: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide.raw,
            Float(globalPoint.x),
            Float(globalPoint.y),
            &ref
        )
        guard error == .success, let ref else {
            return nil
        }

        let element = AXElement(raw: ref)
        return makeRecord(element: element, id: idPath(of: element) ?? "",
                          maxValueLength: 200, profile: .full)
    }

    func resolve(id: String, app: ResolvedApp) throws -> AXElement {
        let path = try Self.parseIDPath(id)
        var element = AXElement.application(pid: app.pid)
        for (step, index) in path.enumerated() {
            let count = element.childCount
            guard index < count, let child = element.childrenPage(start: index, length: 1).first?.element else {
                throw ScreenCommanderError.invalidArguments(
                    "Element id '\(id)' does not resolve: component \(step) asks for child "
                        + "\(index) but only \(count) children exist. Re-read the tree "
                        + "with 'elements' — ids are positional and change with the UI."
                )
            }
            element = child
        }
        return element
    }

    func readResolved(id: String, app: ResolvedApp) throws -> (element: AXElement, record: AXElementRecord) {
        let path = try Self.parseIDPath(id)
        guard path.count <= AXTreeOptions().maxDepth else { throw Self.notFound(id: id, app: app) }
        let diagnostics = AXReadDiagnostics()
        let appElement = AXElement.application(pid: app.pid, diagnostics: diagnostics)
        let priming = prime(appElement)
        defer { priming.restore() }
        let roots = try rootElements(appElement: appElement, app: app, options: AXTreeOptions())
        let resolved = try Self.resolvePath(
            id: id,
            roots: roots.map { (path: $0.path, node: $0.node) },
            childAt: { element, index in
                guard index < element.childCount else { return nil }
                return element.childrenPage(start: index, length: 1).first?.element
            }
        )
        if diagnostics.hadTransientError {
            throw ScreenCommanderError.axTreeUnavailable("Accessibility read for '\(app.name)' was incomplete; re-read the tree.")
        }
        guard let resolved else { throw Self.notFound(id: id, app: app) }
        let record = makeRecord(element: resolved, id: id, maxValueLength: 200, profile: .full)
        if diagnostics.hadTransientError {
            throw ScreenCommanderError.axTreeUnavailable("Accessibility read for '\(app.name)' was incomplete; re-read the tree.")
        }
        return (resolved, record)
    }

    /// The first component must identify one of the same focused-window roots
    /// used by a default tree read. Stale or out-of-scope paths return nil.
    static func resolvePath<Node>(
        id: String,
        roots: [(path: [Int], node: Node)],
        childAt: (Node, Int) -> Node?
    ) throws -> Node? {
        let path = try parseIDPath(id)
        guard let root = roots.first(where: { $0.path == [path[0]] }) else { return nil }
        var current = root.node
        for index in path.dropFirst() {
            guard let child = childAt(current, index) else { return nil }
            current = child
        }
        return current
    }

    private static func notFound(id: String, app: ResolvedApp) -> ScreenCommanderError {
        .elementNotFound(
            "No element with id '\(id)' in '\(app.name)'. Ids are positional and "
                + "change with the UI — re-read the tree with 'elements --app \(app.name)'."
        )
    }

    /// Parses a dot-joined child-index path ("0.3.2" → [0, 3, 2]).
    static func parseIDPath(_ id: String) throws -> [Int] {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, !components.isEmpty else {
            throw ScreenCommanderError.invalidArguments(
                "Element id must be a dot-joined child-index path like '0.3.2'; got an empty id."
            )
        }
        return try components.map { component in
            guard let index = Int(component), index >= 0 else {
                throw ScreenCommanderError.invalidArguments(
                    "Element id must be a dot-joined child-index path like '0.3.2'; got '\(id)'."
                )
            }
            return index
        }
    }

    // MARK: - Record building

    private func makeRecord(element: AXElement, id: String, maxValueLength: Int,
                            profile: AXTreeOptions.Profile, deadlineNanos: UInt64? = nil) -> AXElementRecord {
        // Large editable text may expose a UTF-16 character count and a ranged
        // string API. Only use it when the returned prefix proves truncation;
        // otherwise the ordinary AXValue read preserves exact output.
        var rangedValue: (value: String, truncated: Bool)?
        if profile == .text,
           let role = element.role,
           ["AXTextArea", "AXTextField", "AXStaticText"].contains(role),
           let characterCount = (element.copyAttribute("AXNumberOfCharacters") as? NSNumber)?.intValue,
           characterCount > max(2048, maxValueLength) {
            rangedValue = Self.rangedTextValue(characterCount: characterCount,
                                               maxValueLength: maxValueLength) { length in
                self.prepare(element, deadlineNanos: deadlineNanos)
                return element.string(forRange: 0, length: length)
            }
        }

        let names = profile == .text ? Self.textAttributeNames : Self.fullAttributeNames
        let selectedNames = rangedValue == nil ? names : names.filter { $0 != kAXValueAttribute }
        prepare(element, deadlineNanos: deadlineNanos)
        let values = element.attributeValues(selectedNames)
        let attributes = Dictionary(uniqueKeysWithValues: zip(selectedNames, values))

        func stringAt(_ name: String) -> String? {
            attributes[name].flatMap { $0 }.flatMap(AXElement.coerceToString)
        }
        func boolAt(_ name: String) -> Bool? {
            guard let ref = attributes[name].flatMap({ $0 }), CFGetTypeID(ref) == CFBooleanGetTypeID() else {
                return nil
            }
            return CFBooleanGetValue((ref as! CFBoolean))
        }

        let role = stringAt(kAXRoleAttribute) ?? "AXUnknown"
        var value = rangedValue?.value ?? stringAt(kAXValueAttribute)
        var valueTruncated: Bool?
        if let rangedValue {
            valueTruncated = rangedValue.truncated ? true : nil
        } else if let fullValue = value {
            let (shortened, truncated) = AXElementRecord.truncatedValue(fullValue, maxLength: maxValueLength)
            value = shortened
            if truncated {
                valueTruncated = true
            }
        }

        prepare(element, deadlineNanos: deadlineNanos)
        return AXElementRecord(
            id: id,
            role: role,
            subrole: stringAt(kAXSubroleAttribute),
            title: stringAt(kAXTitleAttribute),
            value: value,
            valueTruncated: valueTruncated,
            description: stringAt(kAXDescriptionAttribute),
            enabled: boolAt(kAXEnabledAttribute) ?? true,
            focused: boolAt(kAXFocusedAttribute),
            actions: profile == .full ? element.actionNames : [],
            boundsPoints: profile == .full ? Self.batchedFrame(attributes).map(RectD.init) : nil,
            boundsPixels: nil
        )
    }

    private static func batchedFrame(_ values: [String: CFTypeRef?]) -> CGRect? {
        if let rect = AXElement.rectValue(values["AXFrame"].flatMap({ $0 })) { return rect }
        guard let point = AXElement.pointValue(values[kAXPositionAttribute].flatMap({ $0 })),
              let size = AXElement.sizeValue(values[kAXSizeAttribute].flatMap({ $0 })) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// AXStringForRange uses UTF-16 offsets. A prefix with more than maxLength
    /// Swift characters is sufficient to reproduce the normal truncation result.
    static func rangedTextValue(characterCount: Int, maxValueLength: Int,
                                fetch: (Int) -> String?) -> (value: String, truncated: Bool)? {
        guard characterCount > 0, maxValueLength >= 0 else { return nil }
        let wanted = maxValueLength.addingReportingOverflow(1)
        let multiplied = wanted.partialValue.multipliedReportingOverflow(by: 4)
        let units = wanted.overflow || multiplied.overflow ? Int.max : multiplied.partialValue
        let length = min(characterCount, min(8192, max(64, units)))
        guard let prefix = fetch(length) else { return nil }
        let shortened = AXElementRecord.truncatedValue(prefix, maxLength: maxValueLength)
        if shortened.truncated { return shortened }
        if length == characterCount { return (prefix, false) }
        return nil
    }

    // MARK: - Roots

    private func rootElements(
        appElement: AXElement,
        app: ResolvedApp,
        options: AXTreeOptions,
        deadlineNanos: UInt64? = nil
    ) throws -> [(path: [Int], node: AXElement, visibleRect: CGRect?)] {
        let appChildren = appElement.indexedChildren {
            guard !Self.hasExpired(deadlineNanos) else { return false }
            prepare(appElement, deadlineNanos: deadlineNanos)
            return true
        }
        if Self.hasExpired(deadlineNanos) { return [] }

        func rootEntry(_ element: AXElement) -> (path: [Int], node: AXElement, visibleRect: CGRect?)? {
            if Self.hasExpired(deadlineNanos) { return nil }
            guard let index = appChildren.first(where: { CFEqual($0.element.raw, element.raw) })?.index else {
                return nil
            }
            prepare(element, deadlineNanos: deadlineNanos)
            return (path: [index], node: element, visibleRect: options.visibleOnly ? element.frame : nil)
        }

        if let windowID = options.windowID {
            for window in appElement.windows {
                if Self.hasExpired(deadlineNanos) { return [] }
                prepare(window, deadlineNanos: deadlineNanos)
                if window.windowID == windowID, let entry = rootEntry(window) {
                    return [entry]
                }
            }
            if Self.hasExpired(deadlineNanos) { return [] }
            throw ScreenCommanderError.invalidArguments(
                "App '\(app.name)' has no window with id \(windowID). "
                    + "Use 'elements --app \(app.name) --all-windows' to inspect every window."
            )
        }

        if options.allWindows {
            let entries = appElement.windows.compactMap(rootEntry)
            if Self.hasExpired(deadlineNanos) { return [] }
            if !entries.isEmpty {
                return entries
            }
        } else {
            if let focused = appElement.focusedWindow, let entry = rootEntry(focused) {
                return [entry]
            }
            if Self.hasExpired(deadlineNanos) { return [] }
            if let first = appElement.windows.first, let entry = rootEntry(first) {
                return [entry]
            }
        }

        if Self.hasExpired(deadlineNanos) { return [] }

        // No windows (or windows not among AX children): traverse everything the app
        // element exposes (menu bar, hidden windows, ...).
        var roots: [(path: [Int], node: AXElement, visibleRect: CGRect?)] = []
        for (index, element) in appChildren {
            if Self.hasExpired(deadlineNanos) { break }
            prepare(element, deadlineNanos: deadlineNanos)
            roots.append((path: [index], node: element,
                          visibleRect: options.visibleOnly ? element.frame : nil))
        }
        return roots
    }

    /// Best-effort child-index path for a hit-tested element, computed by walking the
    /// parent chain up to the app element. Returns nil when any hop cannot be indexed.
    private func idPath(of element: AXElement) -> String? {
        var indices: [Int] = []
        var current = element
        var hops = 0

        while hops < 128 {
            guard let parent = current.parent else {
                break
            }
            guard let index = parent.indexedChildren().first(where: { CFEqual($0.element.raw, current.raw) })?.index else {
                return nil
            }
            indices.append(index)
            if parent.role == kAXApplicationRole as String {
                break
            }
            current = parent
            hops += 1
        }

        guard !indices.isEmpty else {
            return nil
        }
        return indices.reversed().map(String.init).joined(separator: ".")
    }

    // MARK: - Electron/Chromium priming

    private struct Priming {
        var axPrimed: Bool
        /// When AXEnhancedUserInterface was used, its prior value to restore afterwards
        /// (the attribute has known window-manager side effects while set).
        var restoreEnhanced: (element: AXElement, priorValue: CFTypeRef?)?

        func restore() {
            guard let restoreEnhanced else { return }
            _ = restoreEnhanced.element.setAttribute(
                "AXEnhancedUserInterface",
                value: restoreEnhanced.priorValue ?? kCFBooleanFalse
            )
        }
    }

    /// Asks Chromium/Electron apps to populate their AX tree: prefers the side-effect
    /// free `AXManualAccessibility`, falling back to `AXEnhancedUserInterface`.
    private func prime(_ appElement: AXElement, deadlineNanos: UInt64? = nil) -> Priming {
        prepare(appElement, deadlineNanos: deadlineNanos)
        if appElement.setAttribute("AXManualAccessibility", value: kCFBooleanTrue) == .success {
            return Priming(axPrimed: true, restoreEnhanced: nil)
        }

        prepare(appElement, deadlineNanos: deadlineNanos)
        let prior = appElement.copyAttribute("AXEnhancedUserInterface")
        prepare(appElement, deadlineNanos: deadlineNanos)
        if appElement.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue) == .success {
            return Priming(axPrimed: true, restoreEnhanced: (appElement, prior))
        }

        return Priming(axPrimed: false, restoreEnhanced: nil)
    }

    private static func deadlineNanos(timeoutMS: Int?) -> UInt64? {
        guard let timeoutMS else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(max(0, timeoutMS)).multipliedReportingOverflow(by: 1_000_000)
        if duration.overflow { return UInt64.max }
        let end = started.addingReportingOverflow(duration.partialValue)
        return end.overflow ? UInt64.max : end.partialValue
    }

    private static func hasExpired(_ deadlineNanos: UInt64?) -> Bool {
        deadlineNanos.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false
    }

    private static func timedOutTree(axPrimed: Bool = false) -> AXTreeResult {
        AXTreeResult(axPrimed: axPrimed, truncated: true, elements: [],
                     visitedCount: 0, partialReason: "timeout")
    }

    /// A deadline is cooperative across AX calls. Each handle's IPC timeout is
    /// capped to the remaining interval; an in-flight call may still finish late.
    private func prepare(_ element: AXElement, deadlineNanos: UInt64?) {
        guard let deadlineNanos else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = deadlineNanos > now ? deadlineNanos - now : 0
        let seconds = max(0.001, Float(Double(remaining) / 1_000_000_000))
        element.setMessagingTimeout(seconds: seconds)
    }
}
