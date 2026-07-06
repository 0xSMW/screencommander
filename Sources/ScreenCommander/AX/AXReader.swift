import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Traversal options for `AccessibilityReading.tree`.
struct AXTreeOptions: Sendable {
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

    init(
        windowID: UInt32? = nil,
        allWindows: Bool = false,
        maxDepth: Int = 40,
        maxElements: Int = 2000,
        roles: [String]? = nil,
        visibleOnly: Bool = false,
        maxValueLength: Int = 200
    ) {
        self.windowID = windowID
        self.allWindows = allWindows
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.roles = roles
        self.visibleOnly = visibleOnly
        self.maxValueLength = maxValueLength
    }
}

/// Result of one tree read.
struct AXTreeResult: Sendable {
    /// Whether Electron/Chromium priming was applied to the app element.
    var axPrimed: Bool
    /// True when traversal stopped at `maxElements`.
    var truncated: Bool
    var elements: [AXElementRecord]
}

/// Read-only accessibility surface, injected into the engine so tests can fake it.
protocol AccessibilityReading {
    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult
    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord?
    /// Resolves a dot-joined child-index path (e.g. "0.3.2") to a live element.
    /// Ids are positional and must be resolved fresh — never cached across UI changes.
    func resolve(id: String, app: ResolvedApp) throws -> AXElement
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
    private static let batchedAttributeNames: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXEnabledAttribute,
        kAXFocusedAttribute
    ]

    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult {
        let appElement = AXElement.application(pid: app.pid)

        let priming = prime(appElement)
        defer { priming.restore() }

        let roots = try rootElements(appElement: appElement, app: app, options: options)
        let walker = AXTreeWalker(
            maxDepth: options.maxDepth,
            maxElements: options.maxElements,
            roles: options.roles,
            visibleOnly: options.visibleOnly
        )

        let walk = walker.walk(roots: roots) { element in
            element.children
        } record: { element, id in
            self.makeRecord(element: element, id: id, maxValueLength: options.maxValueLength)
        }

        if Self.indicatesUnusableTree(
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
            truncated: walk.truncated,
            elements: walk.records
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
        return makeRecord(element: element, id: idPath(of: element) ?? "", maxValueLength: 200)
    }

    func resolve(id: String, app: ResolvedApp) throws -> AXElement {
        let path = try Self.parseIDPath(id)
        var element = AXElement.application(pid: app.pid)
        for (step, index) in path.enumerated() {
            let children = element.children
            guard index < children.count else {
                throw ScreenCommanderError.invalidArguments(
                    "Element id '\(id)' does not resolve: component \(step) asks for child "
                        + "\(index) but only \(children.count) children exist. Re-read the tree "
                        + "with 'elements' — ids are positional and change with the UI."
                )
            }
            element = children[index]
        }
        return element
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

    private func makeRecord(element: AXElement, id: String, maxValueLength: Int) -> AXElementRecord? {
        let values = element.attributeValues(Self.batchedAttributeNames)

        func stringAt(_ index: Int) -> String? {
            values[index].flatMap(AXElement.coerceToString)
        }
        func boolAt(_ index: Int) -> Bool? {
            guard let ref = values[index], CFGetTypeID(ref) == CFBooleanGetTypeID() else {
                return nil
            }
            return CFBooleanGetValue((ref as! CFBoolean))
        }

        let role = stringAt(0) ?? "AXUnknown"

        var value = stringAt(3)
        var valueTruncated: Bool?
        if let fullValue = value {
            let (shortened, truncated) = AXElementRecord.truncatedValue(fullValue, maxLength: maxValueLength)
            value = shortened
            if truncated {
                valueTruncated = true
            }
        }

        return AXElementRecord(
            id: id,
            role: role,
            subrole: stringAt(1),
            title: stringAt(2),
            value: value,
            valueTruncated: valueTruncated,
            description: stringAt(4),
            enabled: boolAt(5) ?? true,
            focused: boolAt(6),
            actions: element.actionNames,
            boundsPoints: element.frame.map(RectD.init),
            boundsPixels: nil
        )
    }

    // MARK: - Roots

    private func rootElements(
        appElement: AXElement,
        app: ResolvedApp,
        options: AXTreeOptions
    ) throws -> [(path: [Int], node: AXElement, visibleRect: CGRect?)] {
        let appChildren = appElement.children

        func rootEntry(_ element: AXElement) -> (path: [Int], node: AXElement, visibleRect: CGRect?)? {
            guard let index = appChildren.firstIndex(where: { CFEqual($0.raw, element.raw) }) else {
                return nil
            }
            return (path: [index], node: element, visibleRect: options.visibleOnly ? element.frame : nil)
        }

        if let windowID = options.windowID {
            for window in appElement.windows {
                if window.windowID == windowID, let entry = rootEntry(window) {
                    return [entry]
                }
            }
            throw ScreenCommanderError.invalidArguments(
                "App '\(app.name)' has no window with id \(windowID). "
                    + "Use 'elements --app \(app.name) --all-windows' to inspect every window."
            )
        }

        if options.allWindows {
            let entries = appElement.windows.compactMap(rootEntry)
            if !entries.isEmpty {
                return entries
            }
        } else {
            if let focused = appElement.focusedWindow, let entry = rootEntry(focused) {
                return [entry]
            }
            if let first = appElement.windows.first, let entry = rootEntry(first) {
                return [entry]
            }
        }

        // No windows (or windows not among AX children): traverse everything the app
        // element exposes (menu bar, hidden windows, ...).
        return appChildren.enumerated().map { index, element in
            (path: [index], node: element, visibleRect: options.visibleOnly ? element.frame : nil)
        }
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
            guard let index = parent.children.firstIndex(where: { CFEqual($0.raw, current.raw) }) else {
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
    private func prime(_ appElement: AXElement) -> Priming {
        if appElement.setAttribute("AXManualAccessibility", value: kCFBooleanTrue) == .success {
            return Priming(axPrimed: true, restoreEnhanced: nil)
        }

        let prior = appElement.copyAttribute("AXEnhancedUserInterface")
        if appElement.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue) == .success {
            return Priming(axPrimed: true, restoreEnhanced: (appElement, prior))
        }

        return Priming(axPrimed: false, restoreEnhanced: nil)
    }
}
