import Foundation
import CoreGraphics
import ArgumentParser
import ScreenCaptureKit
import XCTest
import ScreenCommanderPresence
@testable import ScreenCommander

private final class FakePermissions: PermissionChecking {
    private(set) var screenRecordingChecks = 0
    private(set) var accessibilityChecks = 0
    var allowScreenRecording = true
    var allowAccessibility = true

    func ensureScreenRecordingAccess(prompt: Bool) throws {
        screenRecordingChecks += 1
        if !allowScreenRecording {
            throw ScreenCommanderError.permissionDeniedScreenRecording
        }
    }

    func ensureAccessibilityAccess(prompt: Bool) throws {
        accessibilityChecks += 1
        if !allowAccessibility {
            throw ScreenCommanderError.permissionDeniedAccessibility
        }
    }
}

private final class NoopDisplays: DisplayResolving {
    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        throw ScreenCommanderError.invalidArguments("Display resolution should not be used in this test")
    }
}

private final class FakeDisplays: DisplayResolving {
    private let resolved: ResolvedDisplay

    init(resolved: ResolvedDisplay) {
        self.resolved = resolved
    }

    func resolveDisplay(identifier: String) async throws -> ResolvedDisplay {
        resolved
    }
}

private final class FakeCapturer: ScreenCapturing {
    private let captureResult: CapturedScreenshot
    private(set) var calls: Int = 0

    init(captureResult: CapturedScreenshot) {
        self.captureResult = captureResult
    }

    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot {
        calls += 1
        return captureResult
    }

    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        calls += 1
        return captureResult
    }
}

private final class FakeImageWriter: ImageWriting {
    private(set) var writes: [(url: URL, format: ImageFormat)] = []
    let returnedSize: SizeD

    init(returnedSize: SizeD) {
        self.returnedSize = returnedSize
    }

    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        writes.append((url: url, format: format))
        return returnedSize
    }
}

private final class FakeMetadataStore: SnapshotMetadataStoring {
    let defaultLastMetadataURL: URL
    private(set) var saved: [(metadata: ScreenshotMetadata, at: URL, updateLastAt: URL?)] = []
    private(set) var loadCalls: [URL] = []
    private var storedMetadataByPath: [String: ScreenshotMetadata] = [:]

    init(defaultLastMetadataURL: URL) {
        self.defaultLastMetadataURL = defaultLastMetadataURL
    }

    func save(metadata: ScreenshotMetadata, at metadataURL: URL, updateLastAt lastURL: URL?) throws {
        saved.append((metadata, metadataURL, lastURL))
        storedMetadataByPath[metadataURL.path] = metadata
        if let lastURL {
            storedMetadataByPath[lastURL.path] = metadata
        }
    }

    func load(from metadataURL: URL) throws -> ScreenshotMetadata {
        loadCalls.append(metadataURL)
        guard let metadata = storedMetadataByPath[metadataURL.path] else {
            throw ScreenCommanderError.metadataFailure("Missing metadata at \(metadataURL.path)")
        }
        return metadata
    }

    func seedLoad(_ metadata: ScreenshotMetadata, at url: URL) {
        storedMetadataByPath[url.path] = metadata
    }
}

private final class FakeMouseController: MouseControlling {
    struct ClickCall {
        let point: CGPoint
        let button: MouseButtonChoice
        let doubleClick: Bool
        let tripleClick: Bool
        let primeClick: Bool
        let humanLike: Bool
        let modifiers: [String]
        let destination: MouseEventDestination
    }
    struct ScrollCall {
        let point: CGPoint
        let dx: Int32
        let dy: Int32
        let unit: ScrollUnit
        let destination: MouseEventDestination
    }
    struct DragCall {
        let from: CGPoint
        let to: CGPoint
        let button: MouseButtonChoice
        let steps: Int
        let durationMS: Int
        let destination: MouseEventDestination
    }
    struct MoveCall {
        let point: CGPoint
        let destination: MouseEventDestination
    }

    private(set) var calls: [ClickCall] = []
    private(set) var scrollCalls: [ScrollCall] = []
    private(set) var dragCalls: [DragCall] = []
    private(set) var moveCalls: [MoveCall] = []

    /// Simulated per-destination failures for tier-fallback tests.
    var windowClickError: Error?
    var focusAssistedClickError: Error?
    var globalClickError: Error?
    var windowScrollError: Error?

    /// Every destination any call was asked to post to, in order.
    var allDestinations: [MouseEventDestination] {
        calls.map(\.destination) + scrollCalls.map(\.destination) + dragCalls.map(\.destination) + moveCalls.map(\.destination)
    }

    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String],
        destination: MouseEventDestination
    ) throws {
        switch destination {
        case .window, .pid:
            if let windowClickError { throw windowClickError }
        case .focusAssisted:
            if let focusAssistedClickError { throw focusAssistedClickError }
        case .global:
            if let globalClickError { throw globalClickError }
        }
        calls.append(
            ClickCall(
                point: point,
                button: button,
                doubleClick: doubleClick,
                tripleClick: tripleClick,
                primeClick: primeClick,
                humanLike: humanLike,
                modifiers: modifiers,
                destination: destination
            )
        )
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit, destination: MouseEventDestination) throws {
        if case .window = destination, let windowScrollError {
            throw windowScrollError
        }
        scrollCalls.append(ScrollCall(point: point, dx: dx, dy: dy, unit: unit, destination: destination))
    }

    func drag(
        from start: CGPoint,
        to end: CGPoint,
        button: MouseButtonChoice,
        steps: Int,
        durationMS: Int,
        destination: MouseEventDestination
    ) throws {
        dragCalls.append(DragCall(from: start, to: end, button: button, steps: steps, durationMS: durationMS, destination: destination))
    }

    func move(to point: CGPoint, destination: MouseEventDestination) throws {
        moveCalls.append(MoveCall(point: point, destination: destination))
    }
}

private final class FakeKeyboardController: KeyboardControlling {
    var onType: (() -> Void)?
    private(set) var typed: [(text: String, delayMilliseconds: Int?)] = []
    private(set) var pasted: [String] = []
    private(set) var pressed: [ParsedKeyChord] = []
    private(set) var systemPressed: [SystemKey] = []
    private(set) var runs: [KeySequence] = []
    private(set) var destinations: [InputEventDestination] = []

    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination) throws {
        onType?()
        typed.append((text: text, delayMilliseconds: delayMilliseconds))
        destinations.append(destination)
    }

    func typeByPasting(text: String, destination: InputEventDestination) throws {
        pasted.append(text)
        destinations.append(destination)
    }

    func type(text: String, delayMilliseconds: Int?, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        try withPrepared(destination, beforePosting)
        try type(text: text, delayMilliseconds: delayMilliseconds, destination: destination)
    }

    func typeByPasting(text: String, destination: InputEventDestination, beforePosting: () throws -> Void) throws {
        try withPrepared(destination, beforePosting)
        try typeByPasting(text: text, destination: destination)
    }

    func press(chord: ParsedKeyChord, destination: InputEventDestination) throws {
        pressed.append(chord)
        destinations.append(destination)
    }

    func pressSystemKey(_ key: SystemKey) throws {
        systemPressed.append(key)
        destinations.append(.global)
    }

    func run(sequence: KeySequence, destination: InputEventDestination) throws {
        runs.append(sequence)
        destinations.append(destination)
    }

    /// Destinations a menu press ran inside, in order.
    private(set) var prepared: [InputEventDestination] = []

    func withPrepared(_ destination: InputEventDestination, _ body: () throws -> Void) throws {
        prepared.append(destination)
        try body()
    }
}

/// A scripted menu bar. `enabledReads` lists what successive `isEnabled` reads
/// return per item path, repeating the last value.
final class FakeMenuShortcuts: MenuShortcutResolving, @unchecked Sendable {
    var items: [MenuShortcutItem] = []
    var enabledReads: [String: [Bool]] = [:]
    /// Press results per path, in order; missing means success.
    var pressResults: [String: [AXError]] = [:]
    private(set) var pressed: [String] = []
    private(set) var matched: [(chord: String, pid: pid_t)] = []
    private(set) var invalidated: [pid_t] = []
    private var reads: [String: Int] = [:]

    func add(_ path: [String], character: String, flags: CGEventFlags = .maskCommand, enabled: [Bool] = [true]) {
        items.append(MenuShortcutItem(path: path, shortcut: MenuShortcut(character: character, virtualKey: nil, flags: flags)))
        enabledReads[path.joined(separator: " > ")] = enabled
    }

    func match(chord: ParsedKeyChord, pid: pid_t) -> MenuShortcutItem? {
        matched.append((chord.normalized, pid))
        return AXMenuShortcuts.firstMatch(chord: chord, in: items)
    }

    func isEnabled(_ item: MenuShortcutItem) -> Bool? {
        let key = item.pathDescription
        guard let values = enabledReads[key], !values.isEmpty else { return nil }
        let index = reads[key, default: 0]
        reads[key] = index + 1
        return values[min(index, values.count - 1)]
    }

    func press(_ item: MenuShortcutItem) -> AXError {
        let key = item.pathDescription
        pressed.append(key)
        guard var results = pressResults[key], !results.isEmpty else { return .success }
        let result = results.removeFirst()
        pressResults[key] = results
        return result
    }

    func invalidate(pid: pid_t) {
        invalidated.append(pid)
    }
}

/// Window lookup over a fixed front-to-back list of windows at any layer: pop-up
/// menus, panels, the Dock, the menu bar, document windows, and the desktop all go
/// in `windows`, frontmost first, with their `layer` and `ownerName`.
private final class FakeWindowLocator: WindowLocating {
    var windows: [InputWindowTarget]
    private(set) var hitTests: [(point: CGPoint, pid: pid_t?)] = []

    init(windows: [InputWindowTarget] = []) {
        self.windows = windows
    }

    /// Moves a window to the front of the list, as raising it would.
    func bringToFront(_ windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        windows.insert(windows.remove(at: index), at: 0)
    }

    /// `windows` may include windows that are not on screen (`isOnScreen: false`);
    /// only `window(id:)` and `offScreenWindowIDs` return those.
    func window(id: CGWindowID) -> InputWindowTarget? {
        if let window = windows.first(where: { $0.windowID == id }) {
            return window
        }
        for (pid, ids) in minimized where ids.contains(id) {
            return InputWindowTarget(pid: pid, windowID: id, bounds: .zero, isOnScreen: false)
        }
        return nil
    }

    /// Like the live locator: the topmost window at the point at any layer, Stage
    /// Manager thumbnails included.
    func topWindow(at point: CGPoint, pid: pid_t?) -> InputWindowTarget? {
        hitTests.append((point, pid))
        return windows.first {
            ($0.isOnScreen || $0.isStageManagerThumbnail) && (pid == nil || $0.pid == pid) && $0.bounds.contains(point)
        }
    }

    /// Document windows (layer 0) only, like the live locator.
    func frontWindow(pid: pid_t) -> InputWindowTarget? {
        windows.first { $0.isOnScreen && $0.pid == pid && $0.layer == 0 }
            ?? windows.first { $0.isStageManagerThumbnail && $0.pid == pid }
    }

    /// Minimized windows per pid; they are not in `windows`.
    var minimized: [pid_t: [CGWindowID]] = [:]

    /// The key window per app. An app not listed has its front document window key.
    var keyWindows: [pid_t: CGWindowID] = [:]

    func minimizedWindowIDs(pid: pid_t) -> [CGWindowID] {
        minimized[pid] ?? []
    }

    func offScreenWindowIDs(pid: pid_t) -> [CGWindowID] {
        minimizedWindowIDs(pid: pid) + windows.filter { !$0.isOnScreen && $0.pid == pid }.map(\.windowID)
    }
}

extension FakeWindowLocator: KeyWindowReading {
    func keyWindowID(pid: pid_t) -> CGWindowID? {
        keyWindows[pid] ?? frontWindow(pid: pid)?.windowID
    }
}

/// Returns scripted samples in order (repeating the last one) and never sleeps.
private final class FakeFocusSampler: FocusSampling {
    var samples: [FocusSample]
    private(set) var sampleCount = 0
    private(set) var settleCount = 0

    init(samples: [FocusSample] = [FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 5, y: 5))]) {
        self.samples = samples
    }

    func sample() -> FocusSample {
        defer { sampleCount += 1 }
        return samples[min(sampleCount, samples.count - 1)]
    }

    func settle() {
        settleCount += 1
    }
}

private final class FakeRetentionManager: CaptureRetentionManaging {
    struct Call: Equatable {
        let directory: URL
        let olderThan: TimeInterval
        let now: Date
    }

    var result = CleanupResult(deletedCount: 0, deletedBytesApprox: 0)
    private(set) var calls: [Call] = []

    func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult {
        calls.append(Call(directory: directory, olderThan: olderThan, now: now))
        return result
    }
}

private final class FakeTargetResolver: TargetResolving {
    var apps: [String: ResolvedApp] = [:]
    var windowList: [WindowInfo] = []
    var windowByIdentifier: [String: WindowInfo] = [:]
    private(set) var resolveWindowCalls: [String] = []

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        guard let app = apps[identifier] else {
            throw ScreenCommanderError.appNotFound("No app for '\(identifier)' in fake.")
        }
        return app
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        if let app {
            return windowList.filter { $0.pid == app.pid }
        }
        return windowList
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        resolveWindowCalls.append(identifier)
        guard let info = windowByIdentifier[identifier] else {
            throw ScreenCommanderError.windowNotFound("No window for '\(identifier)' in fake.")
        }
        // SCWindow cannot be constructed in tests; FakeCapturer ignores it.
        return ResolvedWindow(info: info, scWindow: nil)
    }
}

private final class FakeAccessibilityReader: AccessibilityReading {
    var treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [])
    /// When non-empty, each `tree` call consumes the next result (fresh-resolution tests).
    var treeResults: [AXTreeResult] = []
    var treeError: Error?
    private(set) var treeCalls: [(app: ResolvedApp, options: AXTreeOptions)] = []
    var elementAtResult: AXElementRecord?
    private(set) var elementAtCalls: [CGPoint] = []
    var resolveError: Error?
    private(set) var resolveCalls: [(id: String, app: ResolvedApp)] = []

    func tree(app: ResolvedApp, options: AXTreeOptions) throws -> AXTreeResult {
        treeCalls.append((app, options))
        if let treeError {
            throw treeError
        }
        if let windowID = options.windowID, let windowTree = windowTrees[windowID] {
            return windowTree
        }
        if options.windowID != nil, let windowTreeError {
            throw windowTreeError
        }
        if !treeResults.isEmpty {
            return treeResults.removeFirst()
        }
        return treeResult
    }

    func elementAt(globalPoint: CGPoint) throws -> AXElementRecord? {
        elementAtCalls.append(globalPoint)
        return elementAtResult
    }

    func resolve(id: String, app: ResolvedApp) throws -> AXElement {
        resolveCalls.append((id, app))
        if let resolveError {
            throw resolveError
        }
        // AXUIElementCreateApplication only mints a token — safe without TCC grants.
        return AXElement.application(pid: app.pid)
    }

    /// Trees per window for reads limited to one window (`options.windowID`).
    var windowTrees: [UInt32: AXTreeResult] = [:]
    /// Thrown by a read limited to a window with no entry in `windowTrees`, as when
    /// accessibility cannot match the window.
    var windowTreeError: Error?
    /// The window that holds each root (an id's first component). Roots not listed
    /// are in `defaultElementWindow`, the fixture window.
    var rootWindows: [String: CGWindowID] = [:]
    var defaultElementWindow: CGWindowID? = 500

    func windowID(ofElementID id: String, app: ResolvedApp) -> CGWindowID? {
        let root = String(id.split(separator: ".").first ?? "")
        return rootWindows[root] ?? defaultElementWindow
    }
}

private final class FakeAXActions: AXActionPerforming {
    var performError: Error?
    var setValueError: Error?
    var focusError: Error?
    /// What `readValue` reports after delivery; nil models an unreadable value.
    /// A text model (`text` set) takes precedence.
    var readValueResult: String?
    private(set) var performedActions: [String] = []
    private(set) var setValues: [String] = []
    private(set) var focusCount = 0

    /// A live text model: `readValue` returns it, `setValue` replaces it, and
    /// `setSelectedText` splices into it at `selectedRange` when `selectedTextApplies`.
    var text: String?
    /// Attributes `isSettable` reports as settable.
    var settable: Set<String> = []
    /// False models Chromium: the AXSelectedText write succeeds and changes nothing.
    var selectedTextApplies = true
    /// False models an element that accepts an AXValue write and changes nothing.
    var valueApplies = true
    /// Rewrites every value the fake text model takes, like a field formatter.
    var formatter: ((String) -> String)?
    var secure = false
    /// What `focusedTextElement` returns.
    var focusedText: AXElement?
    private(set) var selectedTextWrites: [String] = []
    private(set) var focusedTextLookups: [(pid: pid_t, windowID: CGWindowID?)] = []

    func readValue(of element: AXElement) -> String? {
        text ?? readValueResult
    }

    func setSelectedText(_ value: String, on element: AXElement) throws {
        selectedTextWrites.append(value)
        guard selectedTextApplies, let current = text else { return }
        let spliced = AXTextInput.splice(value, into: current, at: selectedRange)
        text = formatter?(spliced) ?? spliced
        let location = min(selectedRange?.location ?? current.utf16.count, current.utf16.count)
        selectedRange = AXTextRange(location: location + value.utf16.count, length: 0)
    }

    func isSettable(_ attribute: String, on element: AXElement) -> Bool {
        settable.contains(attribute)
    }

    func isSecureText(_ element: AXElement) -> Bool {
        secure
    }

    /// Answers for the first lookups, in order, before `focusedText`.
    var focusedTextAnswers: [AXElement?] = []

    func focusedTextElement(pid: pid_t, windowID: CGWindowID?) -> AXElement? {
        focusedTextLookups.append((pid, windowID))
        if !focusedTextAnswers.isEmpty {
            return focusedTextAnswers.removeFirst()
        }
        return focusedText
    }

    func perform(action: String, on element: AXElement) throws {
        if let performError {
            throw performError
        }
        performedActions.append(action)
    }

    /// Answers `attempt` gives in order, before falling back to `performError`
    /// (a refusal) or success.
    var attemptResults: [AXError] = []
    /// What the element's value reads after an attempt the app did not confirm,
    /// for a press that ran anyway.
    var valueAfterUnconfirmedAttempt: String?
    private(set) var attempts: [(action: String, result: AXError)] = []

    func attempt(action: String, on element: AXElement) -> AXError {
        let result: AXError
        if !attemptResults.isEmpty {
            result = attemptResults.removeFirst()
        } else {
            result = performError == nil ? .success : .actionUnsupported
        }
        attempts.append((action, result))
        if result == .success {
            performedActions.append(action)
        } else if result == .cannotComplete || result == .failure, let changed = valueAfterUnconfirmedAttempt {
            readValueResult = changed
        }
        return result
    }

    private(set) var raisedWindows: [(pid: pid_t, windowID: CGWindowID)] = []
    /// Runs on each raise, for tests that model what raising changes.
    var onRaise: (pid_t, CGWindowID) -> Void = { _, _ in }

    func raiseWindow(pid: pid_t, windowID: CGWindowID) throws {
        raisedWindows.append((pid, windowID))
        onRaise(pid, windowID)
    }

    func setValue(_ value: String, on element: AXElement) throws {
        if let setValueError {
            throw setValueError
        }
        setValues.append(value)
        if text != nil, valueApplies {
            text = formatter?(value) ?? value
        }
    }

    func focus(on element: AXElement) throws {
        if let focusError {
            throw focusError
        }
        focusCount += 1
    }

    /// Selection writes fail until the element is focused when set.
    var selectionNeedsFocus = false
    var selectionError: Error?
    var selectionApplies = true
    var selectedRange: AXTextRange?
    var selectedTextResult: String?
    private(set) var selectionWrites: [AXTextRange] = []

    func setSelectedTextRange(_ range: AXTextRange, on element: AXElement) throws {
        if selectionNeedsFocus, focusCount == 0 {
            throw ScreenCommanderError.elementNotActionable("Setting AXSelectedTextRange failed (cannot complete).")
        }
        if let selectionError { throw selectionError }
        selectionWrites.append(range)
        if selectionApplies { selectedRange = range }
    }

    func readSelectedTextRange(of element: AXElement) -> AXTextRange? {
        selectedRange
    }

    func readSelectedText(of element: AXElement) -> String? {
        selectedTextResult
    }

    var scrollError: Error?
    var scrollOutcome = AXScrollOutcome(method: "AXScrollDownByPage", before: 0, after: 0.25)
    /// Scroll bar positions returned by successive `scrollPosition` reads.
    var scrollPositions: [Double?] = []
    private(set) var pageScrolls: [(direction: ScrollDirection, pages: Int)] = []

    func scrollByPage(_ element: AXElement, direction: ScrollDirection, pages: Int) throws -> AXScrollOutcome {
        if let scrollError {
            throw scrollError
        }
        pageScrolls.append((direction, pages))
        return scrollOutcome
    }

    func scrollPosition(of element: AXElement, direction: ScrollDirection) -> Double? {
        scrollPositions.isEmpty ? nil : scrollPositions.removeFirst()
    }
}

private final class FakeAppCatalog: AppCataloging {
    var running: [RunningAppEntry] = []
    var installed: [InstalledAppEntry] = []
    var installedTruncated = false
    var bundleURLs: [pid_t: URL] = [:]
    private(set) var installedScans = 0

    func runningApps() -> [RunningAppEntry] {
        running
    }

    func installedApps() -> (apps: [InstalledAppEntry], truncated: Bool) {
        installedScans += 1
        return (installed, installedTruncated)
    }

    func bundleURL(pid: pid_t) -> URL? {
        bundleURLs[pid]
    }

    func resolveInstalled(identifier: String) throws -> InstalledAppTarget {
        try AppCatalog.match(identifier: identifier, in: installed)
    }
}

private final class FakeAppLauncher: AppLaunching, @unchecked Sendable {
    var nextPid: pid_t = 4_242
    var ready = true
    var launchError: Error?
    /// Runs when the app is launched (e.g. to script a focus change).
    var onLaunch: () -> Void = {}
    private(set) var launched: [URL] = []
    private(set) var waited: [(pid: pid_t, timeout: TimeInterval)] = []

    func launch(url: URL) async throws -> pid_t {
        if let launchError {
            throw launchError
        }
        launched.append(url)
        onLaunch()
        return nextPid
    }

    func waitUntilReady(pid: pid_t, timeout: TimeInterval) async -> Bool {
        waited.append((pid, timeout))
        return ready
    }
}

private actor WindowResolutionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeTargets: TargetResolving {
    var resolveWindowHandler: ((String) async throws -> ResolvedWindow)?
    var apps: [String: ResolvedApp] = [:]
    var windowList: [WindowInfo] = []
    var windowByIdentifier: [String: WindowInfo] = [:]
    private(set) var resolveCalls: [String] = []
    private(set) var resolveWindowCalls: [String] = []

    /// Report unknown apps as `app_not_found`, like the live resolver.
    var unknownAppIsNotFound = false

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        resolveCalls.append(identifier)
        guard let app = apps[identifier] else {
            if unknownAppIsNotFound {
                throw ScreenCommanderError.appNotFound("No running app matching '\(identifier)'.")
            }
            throw ScreenCommanderError.invalidArguments("No running app matches '\(identifier)'.")
        }
        return app
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        if let app {
            return windowList.filter { $0.pid == app.pid }
        }
        return windowList
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        resolveWindowCalls.append(identifier)
        if let resolveWindowHandler { return try await resolveWindowHandler(identifier) }
        guard let info = windowByIdentifier[identifier] else {
            throw ScreenCommanderError.windowNotFound("No window for '\(identifier)' in fake.")
        }
        return ResolvedWindow(info: info, scWindow: nil)
    }
}

private final class FakeObservationSource: ObservationSource, @unchecked Sendable {
    /// Events yielded (in order) when `events(...)` is called.
    var scriptedEvents: [ObservedEvent] = []
    /// When true, the stream never finishes on its own — it stays open until the
    /// consuming task is cancelled (drives timeout tests deterministically).
    var keepOpen = false
    /// When set, the stream finishes throwing this error after yielding scripted
    /// events — models an observer-setup failure (AXObserverCreate / registration).
    var setupError: Error?

    private(set) var requestedApp: ResolvedApp?
    private(set) var requestedKinds: Set<ObservedEventKind>?

    func events(app: ResolvedApp, kinds: Set<ObservedEventKind>) -> AsyncThrowingStream<ObservedEvent, Error> {
        requestedApp = app
        requestedKinds = kinds
        let events = scriptedEvents
        let keepOpen = keepOpen
        let setupError = setupError
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let setupError {
                continuation.finish(throwing: setupError)
            } else if !keepOpen {
                continuation.finish()
            }
        }
    }
}

private final class FakeMetadataFreshnessChecker: MetadataFreshnessChecking {
    var result = MetadataFreshnessResult(
        status: .fresh,
        scope: "display",
        reason: "fresh in fake"
    )
    private(set) var checked: [ScreenshotMetadata] = []

    func freshness(for metadata: ScreenshotMetadata) -> MetadataFreshnessResult {
        checked.append(metadata)
        return result
    }
}

private func make1x1Image() -> CGImage {
    let data = Data([255, 0, 0, 255])
    let provider = CGDataProvider(data: data as CFData)!
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func tempStatePath(_ name: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("screencommander-engine-tests", isDirectory: true)
        .appendingPathComponent(name)

    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private struct InputEngineFixture {
    let engine: ScreenCommanderEngine
    let permissions: FakePermissions
    let metadataStore: FakeMetadataStore
    let mouse: FakeMouseController
    let keyboard: FakeKeyboardController
    let reader: FakeAccessibilityReader
    let axActions: FakeAXActions
    let targets: FakeTargets
    let freshness: FakeMetadataFreshnessChecker
    let windows: FakeWindowLocator
    let focus: FakeFocusSampler
    let state: StatePaths
    let menus: FakeMenuShortcuts
}

/// The default background target: pid 77's window 500 covers the fixture display
/// (global points 100,200 400x300), so mapped points and element centers hit it.
private let fixtureWindow = InputWindowTarget(
    pid: 77,
    windowID: 500,
    bounds: CGRect(x: 100, y: 200, width: 400, height: 300)
)

private func makeInputEngineFixture(
    _ name: String,
    frontmostApp: @escaping () -> ResolvedApp? = { nil },
    activateApp: @escaping (ResolvedApp) throws -> Void = { _ in },
    windows: [InputWindowTarget] = [fixtureWindow],
    focusSamples: [FocusSample]? = nil,
    capabilities: DeliveryCapabilities = .all,
    profile: @escaping (pid_t) -> BackgroundDeliveryProfile = { _ in .native },
    bundleProfile: @escaping (URL?) -> BackgroundDeliveryProfile = { _ in .native },
    appCatalog: AppCataloging = FakeAppCatalog(),
    appLauncher: AppLaunching = FakeAppLauncher(),
    presence: PresenceControlling = DisabledPresenceController(),
    presenceSettings: PresenceSettings = PresenceSettings(defaultSession: "default", cursorEnabled: true),
    presencePolicy: PresencePolicy = PresencePolicy(),
    focusSampler: FocusSampling? = nil,
    menus: FakeMenuShortcuts = FakeMenuShortcuts(),
    keyboardController: KeyboardControlling? = nil,
    keyWindows: KeyWindowReading? = nil
) -> InputEngineFixture {
    let permissions = FakePermissions()
    let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(name).path])
    let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
    let mouse = FakeMouseController()
    let keyboard = FakeKeyboardController()
    let reader = FakeAccessibilityReader()
    let axActions = FakeAXActions()
    let targets = FakeTargets()
    let freshness = FakeMetadataFreshnessChecker()
    let windowLocator = FakeWindowLocator(windows: windows)
    let focus = focusSamples.map(FakeFocusSampler.init(samples:)) ?? FakeFocusSampler()
    let metadata = ScreenshotMetadata(
        capturedAtISO8601: "2026-02-21T00:00:00Z",
        displayID: 123,
        displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
        imageSizePixels: SizeD(w: 800, h: 600),
        pointPixelScale: 2,
        imagePath: "/tmp/test.png"
    )
    metadataStore.seedLoad(metadata, at: state.lastMetadataURL)

    let engine = ScreenCommanderEngine(
        permissions: permissions,
        displays: NoopDisplays(),
        capturer: FakeCapturer(
            captureResult: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 123,
                displayBoundsPoints: CGRect(x: 100, y: 200, width: 400, height: 300),
                pointPixelScale: 2
            )
        ),
        imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
        metadataStore: metadataStore,
        coordinateMapper: CoordinateMapper(),
        mouseController: mouse,
        keyboardController: keyboardController ?? keyboard,
        retention: FakeRetentionManager(),
        accessibilityReader: reader,
        axActions: axActions,
        targets: targets,
        metadataFreshness: freshness,
        frontmostApp: frontmostApp,
        activateApp: activateApp,
        windowLocator: windowLocator,
        keyWindows: keyWindows ?? windowLocator,
        focusSampler: focusSampler ?? focus,
        deliveryCapabilities: capabilities,
        deliveryProfile: profile,
        bundleProfile: bundleProfile,
        appCatalog: appCatalog,
        appLauncher: appLauncher,
        menuShortcuts: menus,
        presence: presence,
        presenceSettings: presenceSettings,
        presencePolicy: presencePolicy,
        textReadBackPause: {},
        statePaths: state,
        fileManager: .default,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    return InputEngineFixture(
        engine: engine,
        permissions: permissions,
        metadataStore: metadataStore,
        mouse: mouse,
        keyboard: keyboard,
        reader: reader,
        axActions: axActions,
        targets: targets,
        freshness: freshness,
        windows: windowLocator,
        focus: focus,
        state: state,
        menus: menus
    )
}

final class ScreenCommanderEngineTests: XCTestCase {
    /// Async replacement for `XCTAssertThrowsError` (which has no async overload).
    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error to be thrown", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    func testOutOfRangeNumbersFailWithInvalidArgumentsInsteadOfTrapping() async throws {
        let fixture = makeInputEngineFixture("numeric-limits", frontmostApp: { Self.targetApp })
        func expectInvalid<T>(_ name: String, _ expression: @autoclosure () async throws -> T) async {
            await assertThrows(try await expression()) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments", name)
                XCTAssertTrue("\(error)".contains("must be between"), "\(name): \(error)")
            }
        }
        await expectInvalid("drag duration", try await fixture.engine.drag(DragRequest(
            x1: 200, y1: 100, x2: 300, y2: 200, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, steps: 2, durationMS: Int.max
        )))
        await expectInvalid("drag steps", try await fixture.engine.drag(DragRequest(
            x1: 200, y1: 100, x2: 300, y2: 200, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, steps: Int.max, durationMS: 0
        )))
        await expectInvalid("move dwell", try await fixture.engine.move(
            MoveRequest(x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil, dwellMS: Int.max)
        ))
        await expectInvalid("type delay", try await fixture.engine.type(
            TypeRequest(text: "a", delayMilliseconds: Int.max, inputMode: .unicode)
        ))
        await expectInvalid("keys sleep", try await fixture.engine.keys(KeysRequest(steps: ["sleep:9223372036854775807"])))
        await expectInvalid("select range", try await fixture.engine.selectText(
            SelectTextRequest(element: "Name", range: AXTextRange(location: Int.max, length: 1))
        ))
        await expectInvalid("observe timeout", try await fixture.engine.observe(
            ObserveRequest(appIdentifier: "TargetApp", kinds: [.value], timeoutMS: Int.max)
        ) { _ in })
        XCTAssertThrowsError(try fixture.engine.cleanup(CleanupRequest(olderThanHours: Int.max))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
    }

    func testTypeRejectsNegativeDelay() async {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("type-negative-delay").path])

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            statePaths: state,
            fileManager: .default
        )

        await assertThrows(try await engine.type(TypeRequest(text: "bad", delayMilliseconds: -5, inputMode: .unicode)))
    }

    func testKeysRejectsSystemKeyModifiersAndAcceptsSystemPressWithoutModifiers() async throws {
        let fixture = makeInputEngineFixture("keys-system", frontmostApp: { ResolvedApp(pid: 77, name: "TargetApp", bundleID: nil) })
        let keyboard = fixture.keyboard

        await assertThrows(try await fixture.engine.keys(KeysRequest(steps: ["press:ctrl+play"], foreground: true)))

        // System keys have no target app, so only the foreground (HID) path can send them.
        await assertThrows(try await fixture.engine.keys(KeysRequest(steps: ["press:mute"]))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertTrue(keyboard.runs.isEmpty)

        let result = try await fixture.engine.keys(KeysRequest(steps: ["press:mute"], foreground: true))
        XCTAssertEqual(result.normalizedSteps, ["press:mute"])
        XCTAssertEqual(result.deliveryMethod, .global)
        XCTAssertEqual(keyboard.systemPressed, [])
        XCTAssertEqual(keyboard.runs.count, 1)
        XCTAssertEqual(keyboard.runs[0].steps[0].normalized, "press:mute")
        XCTAssertEqual(keyboard.destinations, [.global])
    }

    func testCleanupDefaultsTo24HoursWhenNil() {
        let retention = FakeRetentionManager()
        retention.result = CleanupResult(deletedCount: 1, deletedBytesApprox: 9)
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup-default").path])

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try? engine.cleanup(CleanupRequest(olderThanHours: nil))
        XCTAssertEqual(result?.deletedCount, 1)
        XCTAssertEqual(result?.deletedBytesApprox, 9)

        let call = try? XCTUnwrap(retention.calls.first)
        XCTAssertEqual(call?.olderThan, 24 * 60 * 60)
    }

    func testScreenshotWithExplicitOutputAndDisabledLastMetadataUpdate() async throws {
        let resolvedDisplay: ResolvedDisplay
        do {
            resolvedDisplay = try await Displays().resolveDisplay(identifier: "main")
        } catch {
            throw XCTSkip("Display enumeration is unavailable in this environment: \(error)")
        }

        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("screenshot-explicit").path])
        let explicitImagePath = tempStatePath("screenshot-explicit-manual").appendingPathComponent("custom.png").path
        let explicitMetadataPath = tempStatePath("screenshot-explicit-manual").appendingPathComponent("custom.json").path

        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 10, h: 20))
        let retention = FakeRetentionManager()

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: FakeDisplays(resolved: resolvedDisplay),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 555,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: explicitImagePath,
                format: .png,
                metadataPath: explicitMetadataPath,
                includeCursor: false,
                updateLastMetadata: false
            )
        )

        XCTAssertEqual(result.imagePath, explicitImagePath)
        XCTAssertEqual(result.metadataPath, explicitMetadataPath)
        XCTAssertEqual(result.lastMetadataPath, explicitMetadataPath)
        XCTAssertEqual(metadataStore.saved[0].at.path, explicitMetadataPath)
        XCTAssertEqual(metadataStore.saved[0].updateLastAt?.path, explicitMetadataPath)
        XCTAssertEqual(imageWriter.writes[0].url.path, explicitImagePath)
        XCTAssertTrue(retention.calls.isEmpty, "screenshot must not prune captures for explicit output paths either")
    }

    func testClickLoadsDefaultMetadataPathAndMapsPixels() async throws {
        let permissions = FakePermissions()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("click" ).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)

        let expectedMetadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z",
            displayID: 123,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png"
        )
        metadataStore.seedLoad(expectedMetadata, at: state.lastMetadataURL)

        let mouse = FakeMouseController()
        let freshness = FakeMetadataFreshnessChecker()

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 123,
                    displayBoundsPoints: CGRect(x: 100, y: 200, width: 400, height: 300),
                    pointPixelScale: 2
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: mouse,
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            metadataFreshness: freshness,
            windowLocator: FakeWindowLocator(windows: [fixtureWindow]),
            focusSampler: FakeFocusSampler(),
            deliveryCapabilities: .all,
            deliveryProfile: { _ in .native },
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: []
            )
        )

        let click = try XCTUnwrap(mouse.calls.first)

        XCTAssertEqual(result.metadataPath, state.lastMetadataURL.path)
        XCTAssertEqual(click.point.x, 200)
        XCTAssertEqual(click.point.y, 250)
        XCTAssertEqual(click.destination, .window(fixtureWindow), "default coordinate clicks go to the window under the point")
        XCTAssertEqual(result.resolved?.globalX, 200)
        XCTAssertEqual(result.resolved?.globalY, 250)
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.verified, .unknown)
        XCTAssertEqual(result.focus?.preserved, true)
        XCTAssertNil(result.requestedVia)
        XCTAssertEqual(result.metadataFreshness?.status, .fresh)
        XCTAssertEqual(freshness.checked.first?.displayID, expectedMetadata.displayID)
        XCTAssertEqual(metadataStore.loadCalls, [state.lastMetadataURL])
        XCTAssertEqual(permissions.accessibilityChecks, 1)
    }

    func testClickReportsStaleMetadataWithoutStrictFailure() async throws {
        let fixture = makeInputEngineFixture("click-stale-metadata")
        fixture.freshness.result = MetadataFreshnessResult(
            status: .stale,
            scope: "display",
            reason: "display changed"
        )

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: []
            )
        )

        XCTAssertEqual(result.metadataFreshness?.status, .stale)
        XCTAssertEqual(result.metadataFreshness?.reason, "display changed")
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testClickStrictMetadataRejectsKnownStaleMetadata() async {
        let fixture = makeInputEngineFixture("click-strict-stale-metadata")
        fixture.freshness.result = MetadataFreshnessResult(
            status: .stale,
            scope: "display",
            reason: "display changed"
        )

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200,
                    y: 100,
                    coordinateSpace: .pixels,
                    metadataPath: nil,
                    button: .left,
                    doubleClick: false,
                    triple: false,
                    primeClick: false,
                    humanLike: true,
                    modifiers: [],
                    strictMetadata: true
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "stale_metadata")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testScrollCallsMouseController() async throws {
        let fixture = makeInputEngineFixture("scroll")

        let result = try await fixture.engine.scroll(
            ScrollRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                dx: 4,
                dy: -3,
                unit: .pixels
            )
        )

        let call = try XCTUnwrap(fixture.mouse.scrollCalls.first)
        XCTAssertEqual(call.point.x, 200)
        XCTAssertEqual(call.point.y, 250)
        XCTAssertEqual(call.dx, 4)
        XCTAssertEqual(call.dy, -3)
        XCTAssertEqual(call.unit, .pixels)
        XCTAssertEqual(call.destination, .window(fixtureWindow))
        XCTAssertEqual(result.resolved?.globalX, 200)
        XCTAssertEqual(result.resolved?.globalY, 250)
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.dx, 4)
        XCTAssertEqual(result.dy, -3)
        XCTAssertEqual(result.unit, .pixels)
        XCTAssertEqual(result.metadataFreshness?.status, .fresh)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testScrollRequiresNonzeroDelta() async {
        let fixture = makeInputEngineFixture("scroll-zero")

        await assertThrows(
            try await fixture.engine.scroll(
                ScrollRequest(
                    x: 200,
                    y: 100,
                    coordinateSpace: .pixels,
                    metadataPath: nil,
                    dx: 0,
                    dy: 0,
                    unit: .lines
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 0)
        XCTAssertTrue(fixture.mouse.scrollCalls.isEmpty)
    }

    func testDragCallsMouseController() async throws {
        let fixture = makeInputEngineFixture("drag")

        let result = try await fixture.engine.drag(
            DragRequest(
                x1: 200,
                y1: 100,
                x2: 300,
                y2: 200,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .right,
                steps: 8,
                durationMS: 120
            )
        )

        let call = try XCTUnwrap(fixture.mouse.dragCalls.first)
        XCTAssertEqual(call.from.x, 200)
        XCTAssertEqual(call.from.y, 250)
        XCTAssertEqual(call.to.x, 250)
        XCTAssertEqual(call.to.y, 300)
        XCTAssertEqual(call.button, .right)
        XCTAssertEqual(call.steps, 8)
        XCTAssertEqual(call.durationMS, 120)
        XCTAssertEqual(call.destination, .window(fixtureWindow), "drags address the window under the start point")
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.button, .right)
        XCTAssertEqual(result.steps, 8)
        XCTAssertEqual(result.durationMilliseconds, 120)
        XCTAssertEqual(result.metadataFreshness?.status, .fresh)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testMoveCallsMouseController() async throws {
        let fixture = makeInputEngineFixture("move")

        let result = try await fixture.engine.move(
            MoveRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                dwellMS: 0
            )
        )

        let call = try XCTUnwrap(fixture.mouse.moveCalls.first)
        XCTAssertEqual(call.point.x, 200)
        XCTAssertEqual(call.point.y, 250)
        XCTAssertEqual(call.destination, .window(fixtureWindow), "hover goes to the app, not the hardware cursor")
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.dwellMilliseconds, 0)
        XCTAssertEqual(result.resolved.globalX, 200)
        XCTAssertEqual(result.resolved.globalY, 250)
        XCTAssertEqual(result.metadataFreshness?.status, .fresh)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testClickWithModifiers() async throws {
        let fixture = makeInputEngineFixture("click-modifiers")

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .middle,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: ["cmd", "shift"]
            )
        )

        let call = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(call.button, .middle)
        XCTAssertEqual(call.modifiers, ["cmd", "shift"])
        XCTAssertEqual(result.modifiers, ["cmd", "shift"])
    }

    func testClickTriple() async throws {
        let fixture = makeInputEngineFixture("click-triple")

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: true,
                primeClick: false,
                humanLike: true,
                modifiers: []
            )
        )

        let call = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertTrue(call.tripleClick)
        XCTAssertFalse(call.doubleClick)
        XCTAssertTrue(result.triple)
    }

    func testClickDoubleAndTripleMutuallyExclusive() async {
        let fixture = makeInputEngineFixture("click-double-triple")

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200,
                    y: 100,
                    coordinateSpace: .pixels,
                    metadataPath: nil,
                    button: .left,
                    doubleClick: true,
                    triple: true,
                    primeClick: false,
                    humanLike: true,
                    modifiers: []
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 0)
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testSequenceDecodesScrollStep() throws {
        let data = Data(#"{"steps":[{"scroll":{"x":100,"y":200,"dy":-3}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .scroll(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected scroll step.")
        }
        XCTAssertEqual(step.x, 100)
        XCTAssertEqual(step.y, 200)
        XCTAssertEqual(step.dx, nil)
        XCTAssertEqual(step.dy, -3)
    }

    func testSequenceDecodesHorizontalOnlyScrollStep() throws {
        let data = Data(#"{"steps":[{"scroll":{"x":100,"y":200,"dx":10}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .scroll(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected scroll step.")
        }
        XCTAssertEqual(step.dx, 10)
        XCTAssertEqual(step.dy, nil)
    }

    func testClickPrimeIsAHiddenNoOpThatScriptsCanStillPass() throws {
        let command = try ClickCommand.parse(["10", "20", "--raw", "--prime"])
        XCTAssertTrue(command.prime)
        XCTAssertFalse(ClickCommand.helpMessage().contains("--prime"))
        let step = Data(#"{"steps":[{"click":{"x":1,"y":2,"prime":true}}]}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(SequenceFile.self, from: step))
    }

    func testScrollCommandAllowsHorizontalOnlyDelta() throws {
        let command = try ScrollCommand.parse(["100", "200", "--dx", "10"])

        XCTAssertEqual(command.dx, 10)
        XCTAssertEqual(command.dy, 0)
    }

    func testSequenceDecodesDragStep() throws {
        let data = Data(#"{"steps":[{"drag":{"x1":10,"y1":20,"x2":30,"y2":40,"button":"middle","steps":5,"durationMS":90}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .drag(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected drag step.")
        }
        XCTAssertEqual(step.x1, 10)
        XCTAssertEqual(step.y1, 20)
        XCTAssertEqual(step.x2, 30)
        XCTAssertEqual(step.y2, 40)
        XCTAssertEqual(step.button, .middle)
        XCTAssertEqual(step.steps, 5)
        XCTAssertEqual(step.durationMs, 90, "the old durationMS spelling still decodes")
    }

    func testSequenceDecodesMoveStep() throws {
        let data = Data(#"{"steps":[{"move":{"x":100,"y":200,"dwellMS":25}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .move(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected move step.")
        }
        XCTAssertEqual(step.x, 100)
        XCTAssertEqual(step.y, 200)
        XCTAssertEqual(step.dwellMs, 25, "the old dwellMS spelling still decodes")
    }

    func testSequenceDecodesSleepStep() throws {
        let data = Data(#"{"steps":[{"sleep":{"ms":50}}]}"#.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .sleep(let step) = try XCTUnwrap(file.steps.first) else {
            return XCTFail("Expected sleep step.")
        }
        XCTAssertEqual(step.ms, 50)
    }

    func testSequenceRejectsAnUnknownKeyAndNamesTheStep() {
        let data = Data(#"{"steps":[{"sleep":{"ms":1}},{"type":{"ap":"TextEdit","text":"hi"}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: data)) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
            let message = "\(error)"
            XCTAssertTrue(message.contains("Step 2 (type)"), message)
            XCTAssertTrue(message.contains("unknown key 'ap'"), message)
            XCTAssertTrue(message.contains("app"), message)
        }
        let unknownStep = Data(#"{"steps":[{"tap":{}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: unknownStep)) { error in
            XCTAssertTrue("\(error)".contains("Step 1: Unknown step 'tap'"), "\(error)")
        }
        let topLevel = Data(#"{"steps":[{"sleep":{"ms":1}}],"stpes":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: topLevel)) { error in
            XCTAssertTrue("\(error)".contains("'stpes'"), "\(error)")
        }
        let wrongType = Data(#"{"steps":[{"click":{"x":"ten","y":2}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: wrongType)) { error in
            XCTAssertTrue("\(error)".contains("Step 1 (click): 'x' must be a number"), "\(error)")
        }
    }

    func testSequenceTakesTheMCPFieldNamesAndTheOldSpellings() throws {
        let data = Data(#"""
        {"steps":[
          {"drag":{"x1":1,"y1":2,"x2":3,"y2":4,"durationMs":90}},
          {"move":{"x":1,"y":2,"dwellMs":25}},
          {"type":{"text":"a","delayMs":5}},
          {"type":{"text":"b","delayMS":6}},
          {"launch":{"app":"Calculator","timeoutMs":700}},
          {"launch":{"app":"Calculator","timeoutMS":800}}
        ]}
        """#.utf8)
        let steps = try JSONDecoder().decode(SequenceFile.self, from: data).steps
        guard steps.count == 6,
              case .drag(let drag) = steps[0], case .move(let move) = steps[1],
              case .type(let typeA) = steps[2], case .type(let typeB) = steps[3],
              case .launch(let launchA) = steps[4], case .launch(let launchB) = steps[5] else {
            return XCTFail("Unexpected steps \(steps)")
        }
        XCTAssertEqual(drag.durationMs, 90)
        XCTAssertEqual(move.dwellMs, 25)
        XCTAssertEqual([typeA.delayMs, typeB.delayMs], [5, 6])
        XCTAssertEqual([launchA.timeoutMs, launchB.timeoutMs], [700, 800])

        let both = Data(#"{"steps":[{"move":{"x":1,"y":2,"dwellMs":1,"dwellMS":2}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: both)) { error in
            XCTAssertTrue("\(error)".contains("Pass only 'dwellMs'"), "\(error)")
        }
    }

    func testSequenceDecodesAKeysStepAndBoundsSleep() throws {
        let data = Data(#"{"steps":[{"keys":{"app":"TextEdit","steps":["down:shift","press:a","up:shift"],"windowId":7}}]}"#.utf8)
        guard case .keys(let step) = try XCTUnwrap(JSONDecoder().decode(SequenceFile.self, from: data).steps.first) else {
            return XCTFail("Expected keys step.")
        }
        XCTAssertEqual(step.steps, ["down:shift", "press:a", "up:shift"])
        XCTAssertEqual(step.app, "TextEdit")
        XCTAssertEqual(step.windowId, 7)

        let longSleep = Data(#"{"steps":[{"sleep":{"ms":9223372036854775807}}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SequenceFile.self, from: longSleep)) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments", "\(error)")
        }
    }

    func testTypeAndKeysFlowThroughKeyboardController() async throws {
        let frontmost = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
        let fixture = makeInputEngineFixture("typing", frontmostApp: { frontmost })
        let keyboard = fixture.keyboard

        let typed = try await fixture.engine.type(TypeRequest(text: "hello", delayMilliseconds: 25, inputMode: .unicode))
        let pasteInBackground = try await fixture.engine.type(TypeRequest(text: "paste", delayMilliseconds: nil, inputMode: .paste))
        let key = try await fixture.engine.key(KeyRequest(chord: "ctrl+shift+tab"))
        let keys = try await fixture.engine.keys(KeysRequest(steps: ["down:cmd", "press:b", "sleep:10", "up:cmd"]))

        XCTAssertEqual(keyboard.typed.count, 2)
        XCTAssertEqual(keyboard.typed[0].text, "hello")
        XCTAssertEqual(keyboard.typed[0].delayMilliseconds, 25)
        XCTAssertEqual(keyboard.typed[1].text, "paste", "background paste mode types Unicode key events")
        XCTAssertEqual(pasteInBackground.inputMode, .unicode)
        XCTAssertTrue(keyboard.pasted.isEmpty, "the background tiers never touch the pasteboard")
        XCTAssertEqual(keyboard.pressed.count, 1)
        XCTAssertEqual(keyboard.pressed[0].normalized, "shift+ctrl+tab")

        let sequence = try XCTUnwrap(keyboard.runs.first)
        XCTAssertEqual(sequence.steps.count, 4)
        XCTAssertEqual(sequence.steps[0].normalized, "down:cmd")
        XCTAssertEqual(sequence.steps[1].normalized, "press:b")
        XCTAssertEqual(sequence.steps[2].normalized, "sleep:10")
        XCTAssertEqual(sequence.steps[3].normalized, "up:cmd")
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 4)

        // With no target, keyboard input goes to the frontmost app's pid, never the HID
        // tap. A sequence that holds Command needs the window made key.
        XCTAssertEqual(keyboard.destinations, [
            .window(fixtureWindow), .window(fixtureWindow), .window(fixtureWindow),
            .focusAssisted(fixtureWindow, authenticatedKeyboard: false),
        ])
        XCTAssertEqual([typed.deliveryMethod, key.deliveryMethod, keys.deliveryMethod], [.window, .window, .focusAssisted])
    }

    func testKeySupportsSpecialAliasesThroughEngine() async throws {
        let fixture = makeInputEngineFixture("special-alias", frontmostApp: { ResolvedApp(pid: 77, name: "TargetApp", bundleID: nil) })
        let engine = fixture.engine

        let spotlightResult = try await engine.key(KeyRequest(chord: "spotlight", foreground: true))
        let raycastResult = try await engine.key(KeyRequest(chord: "raycast", foreground: true))
        let launchpadResult = try await engine.key(KeyRequest(chord: "launchpad", foreground: true))
        let missionControlResult = try await engine.key(KeyRequest(chord: "missioncontrol", foreground: true))

        XCTAssertEqual(spotlightResult.normalizedChord, "cmd+space")
        XCTAssertEqual(raycastResult.normalizedChord, "cmd+space")
        XCTAssertEqual(launchpadResult.normalizedChord, "launchpad")
        XCTAssertEqual(missionControlResult.normalizedChord, "missioncontrol")
        XCTAssertEqual(fixture.keyboard.pressed.count, 4)
        XCTAssertEqual(fixture.keyboard.destinations, Array(repeating: .global, count: 4))
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 4)
    }

    func testCleanupUsesRetentionManager() throws {
        let permissions = FakePermissions()
        let retention = FakeRetentionManager()
        retention.result = CleanupResult(deletedCount: 3, deletedBytesApprox: 128)

        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup" ).path])
        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try engine.cleanup(CleanupRequest(olderThanHours: 6))
        XCTAssertEqual(result.deletedCount, 3)
        XCTAssertEqual(result.deletedBytesApprox, 128)

        let call = try XCTUnwrap(retention.calls.first)
        XCTAssertEqual(call.directory.standardizedFileURL.path, state.capturesDirectoryURL.standardizedFileURL.path)
        XCTAssertEqual(call.olderThan, 6 * 60 * 60)
    }

    func testCleanupRejectsNegativeAges() {
        let retention = FakeRetentionManager()
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("cleanup-negative" ).path])
        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default
        )

        XCTAssertThrowsError(try engine.cleanup(CleanupRequest(olderThanHours: -1)))
    }

    func testScreenshotUsesManagedCaptureDirectoryForDefaultOutput() async throws {
        let baseStatePath = tempStatePath("screenshot-default").path
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": baseStatePath])

        let resolvedDisplay: ResolvedDisplay
        do {
            resolvedDisplay = try await Displays().resolveDisplay(identifier: "main")
        } catch {
            throw XCTSkip("Display enumeration is unavailable in this environment: \(error)")
        }

        let fakeDisplay = FakeDisplays(resolved: resolvedDisplay)
        let retention = FakeRetentionManager()
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 1920, h: 1080))
        let capturer = FakeCapturer(
            captureResult: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            )
        )

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: fakeDisplay,
            capturer: capturer,
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: retention,
            statePaths: state,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )

        _ = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true
            )
        )

        XCTAssertEqual(capturer.calls, 1)
        XCTAssertEqual(imageWriter.writes.count, 1)
        let writtenURL = imageWriter.writes[0].url
        XCTAssertEqual(writtenURL.deletingLastPathComponent().path, state.capturesDirectoryURL.path)
        XCTAssertEqual(writtenURL.pathExtension, "png")
        XCTAssertEqual(metadataStore.saved.count, 1)
        XCTAssertEqual(metadataStore.saved[0].at.path, writtenURL.deletingPathExtension().appendingPathExtension("json").path)
        XCTAssertTrue(retention.calls.isEmpty, "screenshot must not delete or prune existing captures")
        XCTAssertTrue(metadataStore.saved[0].updateLastAt == state.lastMetadataURL)
    }

    // MARK: - Window and app targeting tests

    func testWindowsListsAllWindows() async throws {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("wp2-windows-all").path])
        let resolver = FakeTargetResolver()
        resolver.windowList = [
            WindowInfo(windowID: 1, title: "Main Window", appName: "Safari", pid: 100, boundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 2, title: "Preferences", appName: "Safari", pid: 100, boundsPoints: RectD(x: 100, y: 100, w: 600, h: 400), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 3, title: "Hidden", appName: "Safari", pid: 100, boundsPoints: RectD(x: -10000, y: -10000, w: 600, h: 400), isOnScreen: false, layer: 0)
        ]

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: CapturedScreenshot(image: make1x1Image(), displayID: 1, displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1), pointPixelScale: 1)),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            statePaths: state
        )

        let result = try await engine.windows(WindowsRequest(appIdentifier: nil))
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].windowID, 1)
        XCTAssertEqual(result.windows[1].windowID, 2)
        XCTAssertFalse(result.windows.contains { !$0.isOnScreen })
    }

    func testWindowsFiltersByApp() async throws {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath("wp2-windows-filtered").path])
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.safari")
        resolver.windowList = [
            WindowInfo(windowID: 1, title: "Safari Win", appName: "Safari", pid: 100, boundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800), isOnScreen: true, layer: 0),
            WindowInfo(windowID: 2, title: "Finder Win", appName: "Finder", pid: 200, boundsPoints: RectD(x: 0, y: 0, w: 800, h: 600), isOnScreen: true, layer: 0)
        ]

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: CapturedScreenshot(image: make1x1Image(), displayID: 1, displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1), pointPixelScale: 1)),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL),
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            statePaths: state
        )

        let result = try await engine.windows(WindowsRequest(appIdentifier: "Safari"))
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].appName, "Safari")
    }

    func testCoordinateMapperWindowBoundsOverridesDisplayBounds() throws {
        // Window at (500, 300) with size 800x600, scale 2.0
        let windowBounds = RectD(x: 500, y: 300, w: 800, h: 600)
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2024-01-01T00:00:00.000Z",
            displayID: 0,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 2560, h: 1600),
            imageSizePixels: SizeD(w: 1600, h: 1200),
            pointPixelScale: 2.0,
            imagePath: "/tmp/test.png",
            windowID: 42,
            windowBoundsPoints: windowBounds
        )

        let mapper = CoordinateMapper()
        // Pixel (200, 100) -> points (100, 50) -> global (500+100, 300+50) = (600, 350)
        let resolved = try mapper.map(x: 200, y: 100, space: .pixels, metadata: metadata)
        XCTAssertEqual(resolved.globalX, 600.0)
        XCTAssertEqual(resolved.globalY, 350.0)
    }

    func testCoordinateMapperWithoutWindowBoundsUsesDisplayBounds() throws {
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2024-01-01T00:00:00.000Z",
            displayID: 1,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 1280, h: 800),
            imageSizePixels: SizeD(w: 2560, h: 1600),
            pointPixelScale: 2.0,
            imagePath: "/tmp/test.png"
        )

        let mapper = CoordinateMapper()
        // Pixel (200, 100) -> points (100, 50) -> global (0+100, 0+50) = (100, 50)
        let resolved = try mapper.map(x: 200, y: 100, space: .pixels, metadata: metadata)
        XCTAssertEqual(resolved.globalX, 100.0)
        XCTAssertEqual(resolved.globalY, 50.0)
    }

    func testMetadataBackwardCompatibilityWithoutWindowFields() throws {
        // Old sidecar JSON without windowID/windowBoundsPoints should still decode
        let json = """
        {
            "capturedAtISO8601": "2024-01-01T00:00:00.000Z",
            "displayID": 1,
            "displayBoundsPoints": {"x": 0, "y": 0, "w": 1280, "h": 800},
            "imageSizePixels": {"w": 2560, "h": 1600},
            "pointPixelScale": 2.0,
            "imagePath": "/tmp/test.png"
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(ScreenshotMetadata.self, from: json)
        XCTAssertNil(metadata.windowID)
        XCTAssertNil(metadata.windowBoundsPoints)
        XCTAssertEqual(metadata.displayID, 1)
    }

    private func makeWindowEngineFixture(
        stateName: String,
        resolver: FakeTargetResolver,
        captured: CapturedScreenshot,
        frontmostApp: @escaping () -> ResolvedApp? = { nil },
        activateApp: @escaping (ResolvedApp) throws -> Void = { _ in }
    ) -> (engine: ScreenCommanderEngine, metadataStore: FakeMetadataStore, imageWriter: FakeImageWriter, state: StatePaths) {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        let imageWriter = FakeImageWriter(returnedSize: SizeD(w: 1600, h: 1200))

        let engine = ScreenCommanderEngine(
            permissions: FakePermissions(),
            displays: NoopDisplays(),
            capturer: FakeCapturer(captureResult: captured),
            imageWriter: imageWriter,
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            targets: resolver,
            frontmostApp: frontmostApp,
            activateApp: activateApp,
            statePaths: state,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return (engine, metadataStore, imageWriter, state)
    }

    func testScreenshotWindowCapturePersistsWindowMetadata() async throws {
        let windowBounds = RectD(x: 500, y: 300, w: 800, h: 600)
        let resolver = FakeTargetResolver()
        resolver.windowByIdentifier["Safari"] = WindowInfo(
            windowID: 42,
            title: "Apple",
            appName: "Safari",
            pid: 100,
            boundsPoints: windowBounds,
            isOnScreen: true,
            layer: 0
        )

        let (engine, metadataStore, _, state) = makeWindowEngineFixture(
            stateName: "wp2-window-shot",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 7,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 2560, height: 1600),
                pointPixelScale: 2
            )
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true,
                windowIdentifier: "Safari"
            )
        )

        XCTAssertEqual(resolver.resolveWindowCalls, ["Safari"])

        // The persisted sidecar carries the resolved window bounds — the exact rect
        // CoordinateMapper later uses to map window-relative pixels to global points.
        XCTAssertEqual(result.metadata.windowID, 42)
        XCTAssertEqual(result.metadata.windowBoundsPoints, windowBounds)
        XCTAssertEqual(result.metadata.displayID, 7)
        XCTAssertEqual(result.metadata.displayBoundsPoints, RectD(x: 0, y: 0, w: 2560, h: 1600))
        XCTAssertEqual(result.metadata.pointPixelScale, 2)

        XCTAssertEqual(metadataStore.saved.count, 1)
        XCTAssertEqual(metadataStore.saved[0].metadata.windowID, 42)
        XCTAssertEqual(metadataStore.saved[0].metadata.windowBoundsPoints, windowBounds)
        XCTAssertEqual(metadataStore.saved[0].updateLastAt, state.lastMetadataURL)

        // The in-memory capture rides along for frame diffing (no PNG re-decode).
        XCTAssertNotNil(result.image)
    }

    func testScreenshotWindowMetadataRoundTripsThroughJSON() async throws {
        let resolver = FakeTargetResolver()
        resolver.windowByIdentifier["77"] = WindowInfo(
            windowID: 77,
            title: "Doc",
            appName: "TextEdit",
            pid: 33,
            boundsPoints: RectD(x: 120, y: 90, w: 640, h: 480),
            isOnScreen: true,
            layer: 0
        )

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-window-roundtrip",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pointPixelScale: 2
            )
        )

        let result = try await engine.screenshot(
            ScreenshotRequest(
                displayIdentifier: "main",
                outputPath: nil,
                format: .png,
                metadataPath: nil,
                includeCursor: false,
                updateLastMetadata: true,
                windowIdentifier: "77"
            )
        )

        let encoded = try JSONEncoder().encode(result.metadata)
        let decoded = try JSONDecoder().decode(ScreenshotMetadata.self, from: encoded)

        XCTAssertEqual(decoded.windowID, 77)
        XCTAssertEqual(decoded.windowBoundsPoints, RectD(x: 120, y: 90, w: 640, h: 480))
        XCTAssertEqual(decoded.displayID, 1)
        XCTAssertEqual(decoded.displayBoundsPoints, RectD(x: 0, y: 0, w: 1440, h: 900))
        XCTAssertEqual(decoded.pointPixelScale, 2)
    }

    func testScreenshotWindowNotFoundPropagates() async {
        let resolver = FakeTargetResolver()

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-window-missing",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            )
        )

        do {
            _ = try await engine.screenshot(
                ScreenshotRequest(
                    displayIdentifier: "main",
                    outputPath: nil,
                    format: .png,
                    metadataPath: nil,
                    includeCursor: false,
                    updateLastMetadata: true,
                    windowIdentifier: "Nope"
                )
            )
            XCTFail("Expected window_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "window_not_found")
            XCTAssertEqual(error.exitCode, 80)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - focus

    func testFocusActivatesResolvedAppAndReportsPriorApp() async throws {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let finder = ResolvedApp(pid: 200, name: "Finder", bundleID: "com.apple.finder")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        var activated: [ResolvedApp] = []
        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            frontmostApp: { finder },
            activateApp: { activated.append($0) }
        )

        let result = try await engine.focus(FocusRequest(appIdentifier: "Safari"))

        XCTAssertEqual(result.app, safari)
        XCTAssertEqual(result.priorApp, finder)
        XCTAssertEqual(activated, [safari])
    }

    func testFocusReportsNilPriorAppWhenNoneIsFrontmost() async throws {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-no-prior",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            frontmostApp: { nil }
        )

        let result = try await engine.focus(FocusRequest(appIdentifier: "Safari"))

        XCTAssertEqual(result.app, safari)
        XCTAssertNil(result.priorApp)
    }

    func testFocusThrowsAppNotFoundWhenAppIsGoneAtActivation() async {
        let safari = ResolvedApp(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
        let resolver = FakeTargetResolver()
        resolver.apps["Safari"] = safari

        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-gone",
            resolver: resolver,
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            activateApp: { app in
                throw ScreenCommanderError.appNotFound("App with PID \(app.pid) is no longer running.")
            }
        )

        do {
            _ = try await engine.focus(FocusRequest(appIdentifier: "Safari"))
            XCTFail("Expected app_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "app_not_found")
            XCTAssertEqual(error.exitCode, 81)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFocusPropagatesAppNotFoundFromResolver() async {
        let (engine, _, _, _) = makeWindowEngineFixture(
            stateName: "wp2-focus-unresolved",
            resolver: FakeTargetResolver(),
            captured: CapturedScreenshot(
                image: make1x1Image(),
                displayID: 1,
                displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointPixelScale: 1
            ),
            activateApp: { _ in XCTFail("Activation must not run when resolution fails") }
        )

        do {
            _ = try await engine.focus(FocusRequest(appIdentifier: "Ghost"))
            XCTFail("Expected app_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "app_not_found")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - sleep helper

    func testSleepTimerReturnsImmediatelyForNonPositiveValues() {
        let start = Date()
        SleepTimer.sleep(milliseconds: 0)
        SleepTimer.sleep(milliseconds: -5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testSleepTimerChunkFitsInUseconds() {
        // Guards the overflow fix: a full chunk converted to microseconds must fit
        // in useconds_t (UInt32), so huge sleep/dwell values can never trap.
        XCTAssertLessThanOrEqual(SleepTimer.maxChunkMilliseconds * 1_000, UInt64(UInt32.max))
    }

    // MARK: - elements (AX read core)

    private func makeElementsEngine(
        stateName: String,
        permissions: FakePermissions = FakePermissions(),
        reader: FakeAccessibilityReader,
        targets: FakeTargets = FakeTargets(),
        frontmostApp: @escaping () -> ResolvedApp? = { nil }
    ) -> (engine: ScreenCommanderEngine, metadataStore: FakeMetadataStore, state: StatePaths) {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)

        let engine = ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            accessibilityReader: reader,
            targets: targets,
            frontmostApp: frontmostApp,
            statePaths: state,
            fileManager: .default
        )
        return (engine, metadataStore, state)
    }

    func testElementsDefaultsToFrontmostAppAndChecksAccessibility() async throws {
        let permissions = FakePermissions()
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: true,
            truncated: true,
            elements: [AXElementRecord(id: "0", role: "AXWindow", title: "Doc")]
        )
        let frontmost = ResolvedApp(pid: 42, name: "TextEdit", bundleID: "com.apple.TextEdit")

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-frontmost",
            permissions: permissions,
            reader: reader,
            frontmostApp: { frontmost }
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertEqual(permissions.accessibilityChecks, 1)
        XCTAssertEqual(reader.treeCalls.count, 1)
        XCTAssertEqual(reader.treeCalls[0].app, frontmost)
        XCTAssertEqual(result.app, frontmost)
        XCTAssertTrue(result.axPrimed)
        XCTAssertTrue(result.truncated)
        XCTAssertNil(result.metadataPath)
        XCTAssertEqual(result.elements.map(\.id), ["0"])
        XCTAssertNil(result.text)
    }

    func testElementsResolvesAppIdentifierThroughTargetsAndForwardsOptions() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXWindow")]
        )
        let targets = FakeTargets()
        let safari = ResolvedApp(pid: 7, name: "Safari", bundleID: "com.apple.Safari")
        targets.apps["Safari"] = safari

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-app",
            reader: reader,
            targets: targets,
            frontmostApp: { ResolvedApp(pid: 1, name: "WrongApp", bundleID: nil) }
        )

        let request = ElementsRequest(
            appIdentifier: "Safari",
            windowID: 900,
            maxDepth: 5,
            maxElements: 10,
            roles: ["AXButton"],
            visibleOnly: true,
            maxValueLength: 32
        )
        let result = try await engine.elements(request)

        XCTAssertEqual(targets.resolveCalls, ["Safari"])
        XCTAssertEqual(result.app, safari)
        XCTAssertEqual(result.windowID, 900)

        let options = try XCTUnwrap(reader.treeCalls.first?.options)
        XCTAssertEqual(options.windowID, 900)
        XCTAssertEqual(options.maxDepth, 5)
        XCTAssertEqual(options.maxElements, 10)
        XCTAssertEqual(options.roles, ["AXButton"])
        XCTAssertTrue(options.visibleOnly)
        XCTAssertEqual(options.maxValueLength, 32)
    }

    func testElementsMapsBoundsPixelsFromLastScreenshotMetadata() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [
                AXElementRecord(id: "0", role: "AXWindow", boundsPoints: RectD(x: 150, y: 250, w: 50, h: 40)),
                AXElementRecord(id: "0.0", role: "AXButton", boundsPoints: RectD(x: 600, y: 600, w: 10, h: 10)),
                AXElementRecord(id: "0.1", role: "AXGroup")
            ]
        )

        let (engine, metadataStore, state) = makeElementsEngine(
            stateName: "elements-pixels",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        // Secondary-display-style nonzero origin, scale 2.0 — mirrors CoordinateMapperTests.
        metadataStore.seedLoad(
            ScreenshotMetadata(
                capturedAtISO8601: "2026-07-06T00:00:00Z",
                displayID: 9,
                displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
                imageSizePixels: SizeD(w: 800, h: 600),
                pointPixelScale: 2,
                imagePath: "/tmp/test.png"
            ),
            at: state.lastMetadataURL
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertEqual(result.metadataPath, state.lastMetadataURL.path)
        XCTAssertEqual(result.elements[0].boundsPixels, RectD(x: 100, y: 100, w: 100, h: 80))
        XCTAssertNil(result.elements[1].boundsPixels, "Element outside metadata bounds must have nil pixel bounds")
        XCTAssertNil(result.elements[2].boundsPixels, "Element without a frame must have nil pixel bounds")
    }

    func testElementsOmitsPixelBoundsAndMetadataPathWithoutLastScreenshot() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXWindow", boundsPoints: RectD(x: 0, y: 0, w: 10, h: 10))]
        )

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-no-metadata",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        let result = try await engine.elements(ElementsRequest())

        XCTAssertNil(result.metadataPath)
        XCTAssertNil(result.elements[0].boundsPixels)
        XCTAssertNotNil(result.elements[0].boundsPoints)
    }

    func testElementsSurfacesCorruptLastScreenshotMetadata() async {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXWindow", boundsPoints: RectD(x: 0, y: 0, w: 10, h: 10))]
        )

        let (engine, _, state) = makeElementsEngine(
            stateName: "elements-corrupt-metadata",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )
        try? FileManager.default.createDirectory(
            at: state.lastMetadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not json".utf8).write(to: state.lastMetadataURL)

        await assertThrows(
            try await engine.elements(ElementsRequest())
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "metadata_failure")
        }
    }

    func testElementsTextModePopulatesRenderedText() async throws {
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [
                AXElementRecord(id: "0", role: "AXWindow", title: "Untitled"),
                AXElementRecord(id: "0.0", role: "AXGroup"),
                AXElementRecord(id: "0.0.0", role: "AXTextArea", value: "hello")
            ]
        )

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-text",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        let result = try await engine.elements(ElementsRequest(includeText: true))

        XCTAssertEqual(result.text, "AXWindow \"Untitled\"\n    AXTextArea: hello")
    }

    func testElementsRejectsInvalidLimitsAndConflictingWindowFlags() async {
        let reader = FakeAccessibilityReader()
        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-invalid",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        for request in [
            ElementsRequest(maxDepth: 0),
            ElementsRequest(maxDepth: ScreenCommanderEngine.maximumElementTraversalDepth + 1),
            ElementsRequest(maxElements: 0),
            ElementsRequest(maxElements: ScreenCommanderEngine.maximumElementRecords + 1),
            ElementsRequest(maxValueLength: -1),
            ElementsRequest(windowID: 1, allWindows: true)
        ] {
            do {
                _ = try await engine.elements(request)
                XCTFail("Expected invalid_arguments for request \(request)")
            } catch let error as ScreenCommanderError {
                XCTAssertEqual(error.stableCode, "invalid_arguments")
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
        XCTAssertTrue(reader.treeCalls.isEmpty)
    }

    func testElementsFailsWithoutFrontmostAppOrIdentifier() async {
        let reader = FakeAccessibilityReader()
        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-no-frontmost",
            reader: reader,
            frontmostApp: { nil }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected invalid_arguments")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "invalid_arguments")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElementsPropagatesAxTreeUnavailable() async {
        let reader = FakeAccessibilityReader()
        reader.treeError = ScreenCommanderError.axTreeUnavailable("no tree")

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-unavailable",
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "Electron", bundleID: nil) }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected ax_tree_unavailable")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "ax_tree_unavailable")
            XCTAssertEqual(error.exitCode, 71)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElementsDeniedAccessibilityStopsBeforeReadingTree() async {
        let permissions = FakePermissions()
        permissions.allowAccessibility = false
        let reader = FakeAccessibilityReader()

        let (engine, _, _) = makeElementsEngine(
            stateName: "elements-denied",
            permissions: permissions,
            reader: reader,
            frontmostApp: { ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil) }
        )

        do {
            _ = try await engine.elements(ElementsRequest())
            XCTFail("Expected permission error")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "permission_denied_accessibility")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(reader.treeCalls.isEmpty)
    }

    // MARK: - Pointer-free input (element clicks, --via, tier fallback)

    private static let targetApp = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")

    private func buttonRecord(
        id: String = "0.1",
        role: String = "AXButton",
        title: String? = "Save",
        actions: [String] = ["AXPress"],
        enabled: Bool = true,
        bounds: RectD? = RectD(x: 100, y: 200, w: 40, h: 20)
    ) -> AXElementRecord {
        AXElementRecord(id: id, role: role, title: title, enabled: enabled, actions: actions, boundsPoints: bounds)
    }

    private func makeElementClickFixture(_ name: String, records: [AXElementRecord]) -> InputEngineFixture {
        let fixture = makeInputEngineFixture(name, frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: records)
        return fixture
    }

    private func elementClickRequest(
        element: String? = "Save",
        elementID: String? = nil,
        role: String? = nil,
        app: String? = nil,
        button: MouseButtonChoice = .left,
        double: Bool = false,
        via: InputDeliveryMethod? = nil,
        noCursor: Bool = false,
        strict: Bool = false,
        foreground: Bool = false
    ) -> ClickRequest {
        ClickRequest(
            x: nil,
            y: nil,
            coordinateSpace: .pixels,
            metadataPath: nil,
            button: button,
            doubleClick: double,
            triple: false,
            primeClick: false,
            humanLike: false,
            modifiers: [],
            element: element,
            elementID: elementID,
            role: role,
            appIdentifier: app,
            via: via,
            noCursor: noCursor,
            strict: strict,
            foreground: foreground
        )
    }

    func testElementClickPrefersAXTier() async throws {
        let fixture = makeElementClickFixture("wp5-ax-tier", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest())

        XCTAssertEqual(fixture.axActions.performedActions, ["AXPress"])
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "AX delivery must not synthesize mouse events")
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertNil(result.requestedVia)
        XCTAssertEqual(result.element?.id, "0.1")
        XCTAssertNil(result.resolved)
        XCTAssertNil(result.metadataPath)
        XCTAssertEqual(fixture.reader.resolveCalls.map(\.id), ["0.1"])
        XCTAssertEqual(fixture.reader.resolveCalls.first?.app, Self.targetApp)
        XCTAssertEqual(fixture.permissions.accessibilityChecks, 1)
    }

    func testElementClickFallsBackToWindowWhenAXUnsupported() async throws {
        let fixture = makeElementClickFixture("wp5-window-fallback", records: [buttonRecord(actions: [])])

        let result = try await fixture.engine.click(elementClickRequest())

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(click.destination, .window(fixtureWindow))
        XCTAssertEqual(click.point, CGPoint(x: 120, y: 210), "window clicks land on the element's center")
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.resolved?.globalX, 120)
        XCTAssertEqual(result.resolved?.globalY, 210)
        XCTAssertEqual(result.resolved?.space, .points)
    }

    func testElementClickFallsBackToFocusAssistedWhenWindowFails() async throws {
        let fixture = makeElementClickFixture("wp5-focus-assisted-fallback", records: [buttonRecord(actions: [])])
        fixture.mouse.windowClickError = ScreenCommanderError.inputSynthesisFailed("window post rejected")

        let result = try await fixture.engine.click(elementClickRequest())

        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(click.destination, .focusAssisted(fixtureWindow, authenticatedKeyboard: false))
        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
    }

    func testElementClickForegroundFallsBackToGlobalLast() async throws {
        let fixture = makeElementClickFixture("wp5-global-fallback", records: [buttonRecord(actions: [])])
        fixture.mouse.windowClickError = ScreenCommanderError.inputSynthesisFailed("window post rejected")
        fixture.mouse.focusAssistedClickError = ScreenCommanderError.inputSynthesisFailed("focus records rejected")

        let result = try await fixture.engine.click(elementClickRequest(foreground: true))

        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertEqual(click.destination, .global)
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testElementClickDefaultNeverReachesGlobal() async {
        let fixture = makeElementClickFixture("wp5-no-global", records: [buttonRecord(actions: [])])
        fixture.mouse.windowClickError = ScreenCommanderError.inputSynthesisFailed("window post rejected")
        fixture.mouse.focusAssistedClickError = ScreenCommanderError.inputSynthesisFailed("focus records rejected")

        // --no-cursor is now a no-effect alias; the default already refuses global.
        for noCursor in [false, true] {
            await assertThrows(
                try await fixture.engine.click(elementClickRequest(noCursor: noCursor))
            ) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "input_synthesis_failed")
            }
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "without --foreground nothing may post a global click")
    }

    func testElementClickForcedViaWindowSkipsAX() async throws {
        let fixture = makeElementClickFixture("wp5-via-window", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest(via: .window))

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty, "--via window must not try the AX tier")
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .window(fixtureWindow))
        XCTAssertEqual(result.requestedVia, .window)
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testViaAcceptsLegacyPidSpelling() throws {
        XCTAssertEqual(InputDeliveryMethod(argument: "pid"), .window)
        XCTAssertEqual(try JSONDecoder().decode([InputDeliveryMethod].self, from: Data(#"["pid","focusAssisted"]"#.utf8)), [.window, .focusAssisted])
        XCTAssertNil(InputDeliveryMethod(argument: "hid"))
    }

    func testElementClickForcedViaAXUnsupportedThrows72() async {
        let fixture = makeElementClickFixture("wp5-via-ax-unsupported", records: [buttonRecord(actions: [])])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(via: .ax))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "--via ax must not fall back to mouse delivery")
    }

    func testElementClickDisabledElementStrictThrows72() async {
        let fixture = makeElementClickFixture("wp5-strict-disabled", records: [buttonRecord(enabled: false)])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(strict: true))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "--strict must not downgrade to window/global")
        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
    }

    func testElementClickDisabledElementDefaultThrows72WithoutFallback() async {
        let fixture = makeElementClickFixture("wp5-default-disabled", records: [buttonRecord(enabled: false)])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest())
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
    }

    func testElementClickDisabledElementForcedMouseTierThrows72() async {
        for tier in [InputDeliveryMethod.window, .focusAssisted, .global] {
            let fixture = makeElementClickFixture("wp5-disabled-\(tier.rawValue)", records: [buttonRecord(enabled: false)])

            await assertThrows(
                try await fixture.engine.click(elementClickRequest(via: tier, foreground: tier == .global))
            ) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
                XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
            }
            XCTAssertTrue(fixture.mouse.calls.isEmpty)
            XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
        }
    }

    func testElementClickNotFoundThrows70() async {
        let fixture = makeElementClickFixture("wp5-not-found", records: [buttonRecord(title: "Cancel")])

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(element: "Save"))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_found")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 70)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testElementClickAmbiguousSubstringThrows82() async {
        let fixture = makeElementClickFixture(
            "wp5-ambiguous-element",
            records: [
                buttonRecord(id: "0.1", title: "Save Draft"),
                buttonRecord(id: "0.2", title: "Save As")
            ]
        )

        await assertThrows(
            try await fixture.engine.click(elementClickRequest(element: "Save"))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_ambiguous")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 82)
            XCTAssertTrue(String(describing: error).contains("0.1"))
            XCTAssertTrue(String(describing: error).contains("0.2"))
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
    }

    func testElementClickExactTitleOutranksSubstring() async throws {
        let fixture = makeElementClickFixture(
            "wp5-exact-title",
            records: [
                buttonRecord(id: "0.1", title: "Save As"),
                buttonRecord(id: "0.2", title: "Save")
            ]
        )

        let result = try await fixture.engine.click(elementClickRequest(element: "Save"))

        XCTAssertEqual(result.element?.id, "0.2")
    }

    func testElementClickResolvesFreshOnEveryInvocation() async throws {
        let fixture = makeInputEngineFixture("wp5-fresh-resolution", frontmostApp: { Self.targetApp })
        fixture.reader.treeResults = [
            AXTreeResult(axPrimed: false, truncated: false, elements: [buttonRecord(id: "0.1")]),
            AXTreeResult(axPrimed: false, truncated: false, elements: [buttonRecord(id: "0.4")])
        ]

        let first = try await fixture.engine.click(elementClickRequest())
        let second = try await fixture.engine.click(elementClickRequest())

        XCTAssertEqual(fixture.reader.treeCalls.count, 2, "each click must re-read the tree")
        XCTAssertEqual(fixture.reader.resolveCalls.map(\.id), ["0.1", "0.4"], "ids must be resolved fresh, never cached")
        XCTAssertEqual(first.element?.id, "0.1")
        XCTAssertEqual(second.element?.id, "0.4")
    }

    func testElementClickByIdAndRoleFilter() async throws {
        let records = [
            buttonRecord(id: "0.0", role: "AXStaticText", title: "Save", actions: []),
            buttonRecord(id: "0.2", role: "AXButton", title: "Save")
        ]
        let fixture = makeElementClickFixture("wp5-id-role", records: records)

        // Role filter steers a substring match away from the static text.
        let byRole = try await fixture.engine.click(elementClickRequest(role: "button"))
        XCTAssertEqual(byRole.element?.id, "0.2")

        // Direct id addressing.
        let byID = try await fixture.engine.click(elementClickRequest(element: nil, elementID: "0.2"))
        XCTAssertEqual(byID.element?.id, "0.2")
        XCTAssertEqual(byID.deliveryMethod, .ax)
    }

    func testElementClickResolvesAppThroughTargets() async throws {
        let fixture = makeElementClickFixture("wp5-app-resolution", records: [buttonRecord()])
        let otherApp = ResolvedApp(pid: 99, name: "OtherApp", bundleID: nil)
        fixture.targets.apps["OtherApp"] = otherApp

        _ = try await fixture.engine.click(elementClickRequest(app: "OtherApp"))

        XCTAssertEqual(fixture.targets.resolveCalls, ["OtherApp"])
        XCTAssertEqual(fixture.reader.treeCalls.first?.app, otherApp)
    }

    func testElementClickDoubleClickSkipsAXTier() async throws {
        let fixture = makeElementClickFixture("wp5-double-skips-ax", records: [buttonRecord()])

        let result = try await fixture.engine.click(elementClickRequest(double: true))

        XCTAssertTrue(fixture.axActions.performedActions.isEmpty, "AXPress cannot express a double-click")
        let click = try XCTUnwrap(fixture.mouse.calls.first)
        XCTAssertTrue(click.doubleClick)
        XCTAssertEqual(click.destination, .window(fixtureWindow))
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testElementClickRightButtonUsesAXShowMenu() async throws {
        let fixture = makeElementClickFixture(
            "wp5-show-menu",
            records: [buttonRecord(actions: ["AXPress", "AXShowMenu"])]
        )

        let result = try await fixture.engine.click(elementClickRequest(button: .right))

        XCTAssertEqual(fixture.axActions.performedActions, ["AXShowMenu"])
        XCTAssertEqual(result.deliveryMethod, .ax)
    }

    func testCoordinateClickVerifyTargetIncludesHitElement() async throws {
        let fixture = makeInputEngineFixture("wp5-verify-target")
        let hit = buttonRecord(id: "0.9", title: "OK")
        fixture.reader.elementAtResult = hit

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200,
                y: 100,
                coordinateSpace: .pixels,
                metadataPath: nil,
                button: .left,
                doubleClick: false,
                triple: false,
                primeClick: false,
                humanLike: true,
                modifiers: [],
                verifyTarget: true
            )
        )

        XCTAssertEqual(fixture.reader.elementAtCalls, [CGPoint(x: 200, y: 250)])
        XCTAssertEqual(result.verifiedTarget, hit)
        XCTAssertEqual(fixture.mouse.calls.count, 1, "verification must not suppress the click")
    }

    func testCoordinateClickViaWindowTargetsHitTestOrApp() async throws {
        let other = InputWindowTarget(pid: 88, windowID: 600, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let fixture = makeInputEngineFixture("wp5-coordinate-window", windows: [fixtureWindow, other])

        let hit = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                via: .window
            )
        )
        XCTAssertEqual(fixture.mouse.calls.last?.destination, .window(fixtureWindow), "frontmost window under the point wins")
        XCTAssertEqual(hit.deliveryMethod, .window)
        XCTAssertEqual(hit.requestedVia, .window)

        fixture.targets.apps["Other"] = ResolvedApp(pid: 88, name: "Other", bundleID: nil)
        _ = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                appIdentifier: "Other"
            )
        )
        XCTAssertEqual(fixture.mouse.calls.last?.destination, .window(other), "--app limits the hit test to that app")

        _ = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                windowID: 600
            )
        )
        XCTAssertEqual(fixture.mouse.calls.last?.destination, .window(other), "--window-id addresses that window")
    }

    func testCoordinateClickPrefersScreenshotWindowOverHitTest() async throws {
        let screenshotWindow = InputWindowTarget(pid: 88, windowID: 42, bounds: CGRect(x: 100, y: 200, width: 400, height: 300))
        let fixture = makeInputEngineFixture("coordinate-click-screenshot-window", windows: [fixtureWindow, screenshotWindow])
        fixture.metadataStore.seedLoad(
            ScreenshotMetadata(
                capturedAtISO8601: "2026-02-21T00:00:00Z", displayID: 123,
                displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
                imageSizePixels: SizeD(w: 800, h: 600), pointPixelScale: 2,
                imagePath: "/tmp/window.png", windowID: 42,
                windowBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300)
            ),
            at: fixture.state.lastMetadataURL
        )

        _ = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: []
            )
        )

        XCTAssertEqual(fixture.mouse.calls.first?.destination, .window(screenshotWindow))
        XCTAssertTrue(fixture.windows.hitTests.isEmpty, "screenshot metadata names the window; no hit test needed")
    }

    func testCoordinateClickRefusesAWindowThatIsNotOnScreen() async {
        let hidden = InputWindowTarget(pid: 88, windowID: 42, bounds: CGRect(x: 100, y: 200, width: 400, height: 300), isOnScreen: false)
        let underneath = InputWindowTarget(pid: 99, windowID: 7, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let fixture = makeInputEngineFixture("coordinate-click-off-screen", windows: [underneath, hidden])

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                    button: .left, doubleClick: false, triple: false,
                    primeClick: false, humanLike: true, modifiers: [],
                    windowID: 42
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
            XCTAssertTrue("\(error)".contains("not on screen"), "\(error)")
        }

        // A window capture of the same window names it in the metadata. The click must
        // not fall through to whatever window is on screen at that point now.
        fixture.metadataStore.seedLoad(
            ScreenshotMetadata(
                capturedAtISO8601: "2026-02-21T00:00:00Z", displayID: 123,
                displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
                imageSizePixels: SizeD(w: 800, h: 600), pointPixelScale: 2,
                imagePath: "/tmp/window.png", windowID: 42,
                windowBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300)
            ),
            at: fixture.state.lastMetadataURL
        )
        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                    button: .left, doubleClick: false, triple: false,
                    primeClick: false, humanLike: true, modifiers: []
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty, "nothing is clicked, least of all the window underneath")
        XCTAssertTrue(fixture.windows.hitTests.isEmpty)
    }

    func testKeysToAWindowThatIsNotOnScreenGoToItsPid() async throws {
        let hidden = InputWindowTarget(pid: 77, windowID: 42, bounds: CGRect(x: 100, y: 200, width: 400, height: 300), isOnScreen: false)
        let fixture = makeInputEngineFixture("key-off-screen-window", windows: [hidden])

        let result = try await fixture.engine.key(KeyRequest(chord: "a", windowID: 42))

        XCTAssertEqual(fixture.keyboard.destinations.last, .pid(77))
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testStageManagerThumbnailsAreRecognizedByTheirShrunkBounds() {
        let frame = CGRect(x: 1268, y: 725, width: 420, height: 352)
        XCTAssertTrue(StageManagerThumbnail.isThumbnail(reported: CGRect(x: 16, y: 501, width: 79, height: 97), frame: frame))
        XCTAssertFalse(StageManagerThumbnail.isThumbnail(reported: frame, frame: frame))
        XCTAssertFalse(StageManagerThumbnail.isThumbnail(reported: frame.insetBy(dx: 5, dy: 5), frame: frame))
        XCTAssertFalse(StageManagerThumbnail.isThumbnail(reported: CGRect(x: 0, y: 0, width: 79, height: 97), frame: nil))
    }

    func testStageManagerThumbnailRefusesMouseButTakesKeys() async throws {
        let thumbnail = InputWindowTarget(
            pid: 77, windowID: 42, bounds: CGRect(x: 100, y: 200, width: 400, height: 300),
            isOnScreen: false, isStageManagerThumbnail: true
        )
        let fixture = makeInputEngineFixture("stage-manager-thumbnail", frontmostApp: { Self.targetApp }, windows: [thumbnail])
        fixture.targets.apps["TargetApp"] = Self.targetApp

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                    button: .left, doubleClick: false, triple: false,
                    primeClick: false, humanLike: true, modifiers: [],
                    appIdentifier: "TargetApp"
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
            XCTAssertTrue("\(error)".contains("Stage Manager"), "\(error)")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)

        let typed = try await fixture.engine.type(
            TypeRequest(text: "a", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        )
        XCTAssertEqual(fixture.keyboard.destinations.last, .window(thumbnail), "a thumbnail's window still takes keys")
        XCTAssertEqual(typed.deliveryMethod, .window)
    }

    func testCoordinateClickWithNoWindowFailsWithoutGlobalFallback() async {
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "coordinate-click-no-window",
            activateApp: { activated.append($0) },
            windows: []
        )

        await assertThrows(
            try await fixture.engine.click(
                ClickRequest(
                    x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                    button: .left, doubleClick: false, triple: false,
                    primeClick: false, humanLike: true, modifiers: []
                )
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 51)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(activated.isEmpty)
    }

    func testDefaultBackgroundPathNeverActivatesOrPostsGlobal() async throws {
        let target = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "background-default",
            frontmostApp: { ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal") },
            activateApp: { activated.append($0) }
        )
        fixture.targets.apps["TargetApp"] = target
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.setValueError = ScreenCommanderError.elementNotActionable("read-only")

        let point: (Double, Double) = (200, 100)
        _ = try await fixture.engine.click(ClickRequest(
            x: point.0, y: point.1, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false,
            primeClick: false, humanLike: true, modifiers: [], appIdentifier: "TargetApp"
        ))
        _ = try await fixture.engine.scroll(ScrollRequest(
            x: point.0, y: point.1, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -1, unit: .lines
        ))
        _ = try await fixture.engine.drag(DragRequest(
            x1: 200, y1: 100, x2: 300, y2: 200, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, steps: 2, durationMS: 0
        ))
        _ = try await fixture.engine.move(MoveRequest(x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil, dwellMS: 0))
        _ = try await fixture.engine.type(TypeRequest(text: "a", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp"))
        _ = try await fixture.engine.type(TypeRequest(text: "b", delayMilliseconds: nil, inputMode: .paste, element: "Name", appIdentifier: "TargetApp"))
        _ = try await fixture.engine.key(KeyRequest(chord: "cmd+s", appIdentifier: "TargetApp"))
        _ = try await fixture.engine.keys(KeysRequest(steps: ["press:a"], appIdentifier: "TargetApp"))

        XCTAssertTrue(activated.isEmpty, "background delivery must never activate an app")
        XCTAssertFalse(fixture.mouse.allDestinations.contains(.global))
        XCTAssertFalse(fixture.keyboard.destinations.contains(.global))
        XCTAssertEqual(fixture.mouse.allDestinations.count, 4)
        XCTAssertEqual(fixture.keyboard.destinations.count, 4)
        // cmd+s is no menu item here, so it goes out as key events in a window made
        // key for the action; everything else uses plain window events. Keys typed
        // into the element must reach the element's own window.
        XCTAssertEqual(fixture.keyboard.destinations, [
            .window(fixtureWindow), .window(fixtureWindow.requiringKeyFocus()),
            .focusAssisted(fixtureWindow, authenticatedKeyboard: false), .window(fixtureWindow),
        ])
    }

    func testViaGlobalRequiresForeground() async {
        let fixture = makeInputEngineFixture("via-global-needs-foreground", frontmostApp: { Self.targetApp })

        await assertThrows(
            try await fixture.engine.click(ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [], via: .global
            ))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        await assertThrows(
            try await fixture.engine.type(TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, via: .global))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
    }

    func testForegroundKeyboardActivatesNamedTargetThenPostsGlobal() async throws {
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "foreground-keys",
            frontmostApp: { ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal") },
            activateApp: { activated.append($0) }
        )
        fixture.targets.apps["TargetApp"] = Self.targetApp

        let result = try await fixture.engine.key(KeyRequest(chord: "cmd+s", appIdentifier: "TargetApp", foreground: true))

        XCTAssertEqual(activated, [Self.targetApp])
        XCTAssertEqual(fixture.keyboard.destinations, [.global])
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testTierSelectionFollowsAppProfile() async throws {
        let chromium = BackgroundDeliveryProfile(toolkit: .chromium, preferredTier: .focusAssisted, authenticatedKeyboard: true)
        let fixture = makeInputEngineFixture("tier-profile", profile: { _ in chromium })
        fixture.targets.apps["TargetApp"] = Self.targetApp

        let click = try await fixture.engine.click(ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false,
            primeClick: false, humanLike: true, modifiers: []
        ))
        let typed = try await fixture.engine.type(TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp"))

        XCTAssertEqual(click.deliveryMethod, .focusAssisted)
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .focusAssisted(fixtureWindow, authenticatedKeyboard: true))
        XCTAssertEqual(typed.deliveryMethod, .focusAssisted)
        XCTAssertEqual(fixture.keyboard.destinations, [.focusAssisted(fixtureWindow, authenticatedKeyboard: true)])
    }

    func testMissingSymbolsSkipTheirTiers() async throws {
        // No CGEventSetWindowLocation: no window-addressed mouse tier at all.
        let noWindowLocation = makeInputEngineFixture(
            "missing-window-location",
            frontmostApp: { Self.targetApp },
            capabilities: DeliveryCapabilities(windowLocation: false, focusRecords: true, authenticatedPost: true)
        )
        await assertThrows(
            try await noWindowLocation.engine.click(ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: []
            ))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertTrue(noWindowLocation.mouse.calls.isEmpty)
        // Keyboard needs no window stamping, so it still delivers per pid.
        let key = try await noWindowLocation.engine.key(KeyRequest(chord: "a"))
        XCTAssertEqual(key.deliveryMethod, .window)

        // No focus-record symbols: a profile that lists both tiers falls back from
        // focusAssisted to window, and the authenticated post is dropped when
        // SLEventPostToPid is missing.
        let chromium = BackgroundDeliveryProfile(toolkit: .chromium, preferredTier: .focusAssisted, authenticatedKeyboard: true)
        let noFocusRecords = makeInputEngineFixture(
            "missing-focus-records",
            frontmostApp: { Self.targetApp },
            capabilities: DeliveryCapabilities(windowLocation: true, focusRecords: false, authenticatedPost: false),
            profile: { _ in chromium }
        )
        let click = try await noFocusRecords.engine.click(ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false,
            primeClick: false, humanLike: true, modifiers: []
        ))
        XCTAssertEqual(click.deliveryMethod, .window)
        let chromiumKey = try await noFocusRecords.engine.key(KeyRequest(chord: "a"))
        XCTAssertEqual(chromiumKey.deliveryMethod, .window)
        XCTAssertEqual(noFocusRecords.keyboard.destinations, [.window(fixtureWindow)])

        await assertThrows(
            try await noFocusRecords.engine.click(ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [], via: .focusAssisted
            ))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
    }

    func testSystemShortcutAliasesNeedForegroundButOtherChordsDeliver() async throws {
        let fixture = makeInputEngineFixture("system-shortcut-aliases", frontmostApp: { Self.targetApp })

        for alias in ["spotlight", "raycast", "missioncontrol", "Mission-Control"] {
            await assertThrows(try await fixture.engine.key(KeyRequest(chord: alias))) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
                XCTAssertTrue("\(error)".contains("--foreground"), "\(error)")
            }
        }
        await assertThrows(try await fixture.engine.keys(KeysRequest(steps: ["press:a", "press:spotlight"]))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        await assertThrows(try await fixture.engine.keys(KeysRequest(steps: ["down:missioncontrol", "up:missioncontrol"]))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
        }
        XCTAssertTrue(fixture.keyboard.pressed.isEmpty)
        XCTAssertTrue(fixture.keyboard.runs.isEmpty)

        // F3 typed as a key, and chords an app can handle itself, go to the target as asked.
        let raw = try await fixture.engine.key(KeyRequest(chord: "ctrl+left"))
        XCTAssertEqual(raw.normalizedChord, "ctrl+left")
        _ = try await fixture.engine.keys(KeysRequest(steps: ["press:f3"]))
        XCTAssertEqual(fixture.keyboard.destinations, [.window(fixtureWindow), .window(fixtureWindow)])
    }

    func testSystemWideChordsAreRefusedInTheBackground() async throws {
        let fixture = makeInputEngineFixture("system-wide-chords", frontmostApp: { Self.targetApp })

        for chord in ["cmd+tab", "cmd+shift+tab", "cmd+space", "cmd+option+esc", "ctrl+cmd+q", "cmd+shift+4", "shift+cmd+3"] {
            await assertThrows(try await fixture.engine.key(KeyRequest(chord: chord))) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable", chord)
                XCTAssertTrue("\(error)".contains("system-wide shortcut"), "\(error)")
            }
        }
        for steps in [["press:cmd+tab"], ["down:cmd", "press:tab", "up:cmd"], ["down:cmd", "down:shift", "press:4"]] {
            await assertThrows(try await fixture.engine.keys(KeysRequest(steps: steps))) { error in
                XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable", "\(steps)")
            }
        }
        XCTAssertTrue(fixture.keyboard.pressed.isEmpty)
        XCTAssertTrue(fixture.keyboard.runs.isEmpty)

        // Chords an app handles itself still go out, and so do held modifiers that
        // were released before the key.
        _ = try await fixture.engine.keys(KeysRequest(steps: ["down:cmd", "up:cmd", "press:tab"]))
        _ = try await fixture.engine.key(KeyRequest(chord: "cmd+shift+5", foreground: true))
        XCTAssertNil(KeyCodes.systemWideChord(try KeyCodes.parseChord("cmd+`")))
        XCTAssertNil(KeyCodes.systemWideChord(try KeyCodes.parseChord("cmd+h")))
        XCTAssertNil(KeyCodes.systemWideChord(try KeyCodes.parseChord("ctrl+space")))
        XCTAssertEqual(fixture.keyboard.destinations.last, .global)
    }

    func testCommandShortcutPressesMenuItemThroughAccessibility() async throws {
        let menus = FakeMenuShortcuts()
        menus.add(["Edit", "Select All"], character: "A")
        let fixture = makeInputEngineFixture("cmd-menu", frontmostApp: { Self.targetApp }, menus: menus)

        let result = try await fixture.engine.key(KeyRequest(chord: "cmd+a"))

        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
        XCTAssertEqual(result.menuItem, "Edit > Select All")
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(menus.pressed, ["Edit > Select All"])
        // The chord never went out as key events.
        XCTAssertTrue(fixture.keyboard.pressed.isEmpty)
        // The menu press ran inside focusAssisted, which makes the window key.
        XCTAssertEqual(fixture.keyboard.prepared, [.focusAssisted(fixtureWindow, authenticatedKeyboard: false)])
    }

    func testCommandShortcutFallsBackToTheChordWhenTheItemReadsDisabled() async throws {
        let menus = FakeMenuShortcuts()
        // Disabled on the first read, enabled after the chord makes AppKit validate.
        menus.add(["Edit", "Select All"], character: "A", enabled: [false, true])
        let fixture = makeInputEngineFixture("cmd-menu-validate", frontmostApp: { Self.targetApp }, menus: menus)

        let result = try await fixture.engine.key(KeyRequest(chord: "cmd+a"))

        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
        XCTAssertEqual(result.menuItem, "Edit > Select All")
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertTrue(menus.pressed.isEmpty, "the chord delivered it, not AXPress")
        XCTAssertEqual(fixture.keyboard.pressed.map { $0.normalized }, ["cmd+a"])
        XCTAssertEqual(fixture.keyboard.destinations, [.window(fixtureWindow)])
    }

    func testCommandShortcutStillDisabledFails() async throws {
        let menus = FakeMenuShortcuts()
        menus.add(["Edit", "Select All"], character: "A", enabled: [false])
        let fixture = makeInputEngineFixture("cmd-menu-disabled", frontmostApp: { Self.targetApp }, menus: menus)

        await assertThrows(try await fixture.engine.key(KeyRequest(chord: "cmd+a"))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
        }
    }

    func testCommandShortcutWithNoMenuItemGoesOutAsKeyEvents() async throws {
        let menus = FakeMenuShortcuts()
        let fixture = makeInputEngineFixture("cmd-no-menu", frontmostApp: { Self.targetApp }, menus: menus)

        let result = try await fixture.engine.key(KeyRequest(chord: "cmd+b"))

        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
        XCTAssertNil(result.menuItem)
        XCTAssertEqual(result.verified, .unknown)
        XCTAssertEqual(fixture.keyboard.pressed.map { $0.normalized }, ["cmd+b"])
        XCTAssertEqual(fixture.keyboard.destinations, [.focusAssisted(fixtureWindow, authenticatedKeyboard: false)])
    }

    func testCommandShortcutWithoutAKeyWindowNeedsAMenuItem() async throws {
        // No on-screen window: no window can be made key.
        let menus = FakeMenuShortcuts()
        let fixture = makeInputEngineFixture("cmd-no-window", frontmostApp: { Self.targetApp }, windows: [], menus: menus)

        await assertThrows(try await fixture.engine.key(KeyRequest(chord: "cmd+b"))) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "background_delivery_unavailable")
            XCTAssertTrue("\(error)".contains("key window"), "\(error)")
        }
        // A menu item is still reachable through AX, when it is enabled.
        menus.add(["File", "Save"], character: "S")
        let result = try await fixture.engine.key(KeyRequest(chord: "cmd+s"))
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.menuItem, "File > Save")
        XCTAssertEqual(menus.pressed, ["File > Save"])
    }

        func testFocusReceiptReportsWhatTheSamplerSaw() async throws {
        let before = FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 10, y: 10))
        let after = FocusSample(frontmostPid: 77, frontmostBundleID: "com.example.target", cursor: CGPoint(x: 200, y: 250))
        let fixture = makeInputEngineFixture("focus-receipt", focusSamples: [before, after])

        let result = try await fixture.engine.click(ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false,
            primeClick: false, humanLike: true, modifiers: []
        ))

        // Background delivery never moves the hardware cursor, so the change is the user's.
        XCTAssertEqual(
            result.focus,
            FocusReceipt(preserved: false, frontmostBefore: "com.apple.Terminal", frontmostAfter: "com.example.target", cursorMoved: false)
        )
        XCTAssertEqual(fixture.focus.sampleCount, 2)
        XCTAssertEqual(fixture.focus.settleCount, 1, "the after-sample waits for a short settle")

        let steady = makeInputEngineFixture("focus-receipt-steady", frontmostApp: { Self.targetApp })
        let key = try await steady.engine.key(KeyRequest(chord: "a"))
        XCTAssertEqual(
            key.focus,
            FocusReceipt(preserved: true, frontmostBefore: "com.apple.Terminal", frontmostAfter: "com.apple.Terminal", cursorMoved: false)
        )
    }

    func testCursorMovedCountsOnlyGlobalDelivery() async throws {
        let before = FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 10, y: 10))
        let after = FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 200, y: 250))

        let userMoved = FocusReceipt(before: before, after: after)
        XCTAssertFalse(userMoved.cursorMoved)
        XCTAssertTrue(userMoved.preserved, "the user's own mouse movement does not break preserved")

        let global = FocusReceipt(before: before, after: after, deliveredGlobally: true)
        XCTAssertTrue(global.cursorMoved)
        XCTAssertTrue(global.preserved)
        XCTAssertFalse(FocusReceipt(before: before, after: before, deliveredGlobally: true).cursorMoved)

        let fixture = makeInputEngineFixture("focus-receipt-foreground", focusSamples: [before, after])
        let click = try await fixture.engine.click(ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false,
            primeClick: false, humanLike: true, modifiers: [], foreground: true
        ))
        XCTAssertEqual(click.deliveryMethod, .global)
        XCTAssertEqual(click.focus?.cursorMoved, true)
    }

    func testFocusReceiptCatchesFocusMovingInsideTheFrontmostApp() async throws {
        let base = FocusSample(
            frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 5, y: 5),
            focusedWindow: "window:900", focusedElement: "AXTextArea:1a"
        )
        var windowChanged = base
        windowChanged.focusedWindow = "window:901"
        var elementChanged = base
        elementChanged.focusedElement = "AXTextField:2b"
        var unreadable = base
        unreadable.focusedWindow = nil
        unreadable.focusedElement = nil

        XCTAssertTrue(FocusReceipt(before: base, after: base).preserved)
        XCTAssertFalse(FocusReceipt(before: base, after: windowChanged).preserved, "the user's key window changed")
        XCTAssertFalse(FocusReceipt(before: base, after: elementChanged).preserved, "the user's focused element changed")
        XCTAssertTrue(FocusReceipt(before: base, after: unreadable).preserved, "an AX read that failed on one side is not a change")

        let fixture = makeInputEngineFixture(
            "focus-receipt-element",
            frontmostApp: { Self.targetApp },
            focusSamples: [base, elementChanged]
        )
        let result = try await fixture.engine.key(KeyRequest(chord: "a"))
        XCTAssertEqual(
            result.focus,
            FocusReceipt(
                preserved: false,
                frontmostBefore: "com.apple.Terminal",
                frontmostAfter: "com.apple.Terminal",
                focusedWindowBefore: "window:900",
                focusedWindowAfter: "window:900",
                focusedElementBefore: "AXTextArea:1a",
                focusedElementAfter: "AXTextField:2b",
                cursorMoved: false
            )
        )
    }

    func testReceiptAndVerificationEncodeAsDocumented() throws {
        var result = TypeResult(textLength: 1, delayMilliseconds: nil, inputMode: .paste, deliveryMethod: .focusAssisted)
        result.focus = FocusReceipt(
            preserved: true, frontmostBefore: "a", frontmostAfter: "a",
            focusedWindowBefore: "window:7", focusedWindowAfter: "window:7",
            focusedElementBefore: "AXTextArea:1a", focusedElementAfter: "AXTextArea:1a",
            cursorMoved: false
        )
        result.verified = .unknown
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(json?["deliveryMethod"] as? String, "focusAssisted")
        XCTAssertEqual(json?["verified"] as? String, "unknown")
        let focus = json?["focus"] as? [String: Any]
        XCTAssertEqual(focus?["preserved"] as? Bool, true)
        XCTAssertEqual(focus?["cursorMoved"] as? Bool, false)
        XCTAssertEqual(focus?["frontmostBefore"] as? String, "a")
        XCTAssertEqual(focus?["focusedWindowBefore"] as? String, "window:7")
        XCTAssertEqual(focus?["focusedWindowAfter"] as? String, "window:7")
        XCTAssertEqual(focus?["focusedElementBefore"] as? String, "AXTextArea:1a")
        XCTAssertEqual(focus?["focusedElementAfter"] as? String, "AXTextArea:1a")

        result.verified = .checked(true)
        json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(json?["verified"] as? Bool, true)
    }

    func testBackgroundDeliveryPolicyDetectsChromiumFrameworks() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screencommander-policy-\(UUID().uuidString).app")
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertTrue(BackgroundDeliveryPolicy.isChromiumFamily(bundleURL: bundle))
        XCTAssertFalse(BackgroundDeliveryPolicy.isChromiumFamily(bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        XCTAssertTrue(BackgroundDeliveryPolicy.isChromiumFrameworkName("Google Chrome Framework.framework"))
        XCTAssertFalse(BackgroundDeliveryPolicy.isChromiumFrameworkName("Sparkle.framework"))
    }

    func testCoordinateClickWithAppActivatesBeforeGlobalClick() async throws {
        let target = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
        let other = ResolvedApp(pid: 12, name: "Finder", bundleID: "com.apple.finder")
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "coordinate-click-app-activation",
            frontmostApp: { other },
            activateApp: { activated.append($0) }
        )
        fixture.targets.apps["TargetApp"] = target

        let result = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                appIdentifier: "TargetApp", foreground: true
            )
        )

        XCTAssertEqual(activated, [target])
        XCTAssertEqual(fixture.targets.resolveCalls, ["TargetApp"])
        XCTAssertEqual(fixture.mouse.calls.count, 1)
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .global)
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testCoordinateClickWithAppSkipsActivationWhenAlreadyFrontmost() async throws {
        let target = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "coordinate-click-app-already-frontmost",
            frontmostApp: { target },
            activateApp: { activated.append($0) }
        )
        fixture.targets.apps["TargetApp"] = target

        _ = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                appIdentifier: "TargetApp", foreground: true
            )
        )

        XCTAssertTrue(activated.isEmpty)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testCoordinateClickWithWindowMetadataActivatesOwningApp() async throws {
        let windowApp = ResolvedApp(pid: 88, name: "Safari", bundleID: nil)
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z",
            displayID: 123,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600),
            pointPixelScale: 2,
            imagePath: "/tmp/window.png",
            windowID: 42,
            windowBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300)
        )
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "coordinate-click-window-activation",
            frontmostApp: { ResolvedApp(pid: 12, name: "Finder", bundleID: nil) },
            activateApp: { activated.append($0) }
        )
        fixture.metadataStore.seedLoad(metadata, at: fixture.state.lastMetadataURL)
        fixture.targets.windowByIdentifier["42"] = WindowInfo(
            windowID: 42,
            title: "Main",
            appName: "Safari",
            pid: windowApp.pid,
            boundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            isOnScreen: true,
            layer: 0
        )

        _ = try await fixture.engine.click(
            ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [], foreground: true
            )
        )

        XCTAssertEqual(activated, [windowApp])
        XCTAssertEqual(fixture.targets.resolveWindowCalls, ["42"])
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testCanceledWindowResolutionCannotActivateOrClick() async throws {
        var activated: [ResolvedApp] = []
        let fixture = makeInputEngineFixture(
            "cancelled-window-resolution",
            activateApp: { activated.append($0) }
        )
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z", displayID: 123,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600), pointPixelScale: 2,
            imagePath: "/tmp/window.png", windowID: 42,
            windowBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300)
        )
        fixture.metadataStore.seedLoad(metadata, at: fixture.state.lastMetadataURL)
        let cache = TTLCache<Bool, WindowInfo>(ttl: 2)
        let gate = WindowResolutionGate()
        let started = expectation(description: "Window enumeration started")
        fixture.targets.resolveWindowHandler = { _ in
            let info = try await cache.value(for: true) {
                started.fulfill()
                await gate.wait()
                return WindowInfo(windowID: 42, title: "Main", appName: "Fixture", pid: 88,
                                  boundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
                                  isOnScreen: true, layer: 0)
            }
            return ResolvedWindow(info: info, scWindow: nil)
        }
        let action = Task {
            try await fixture.engine.click(ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [], foreground: true
            ))
        }
        await fulfillment(of: [started], timeout: 2)
        action.cancel()
        await gate.open()
        do { _ = try await action.value; XCTFail("Canceled action should throw") }
        catch is CancellationError {}
        XCTAssertTrue(activated.isEmpty)
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    private func textFieldFixture(_ name: String, text: String?, selection: AXTextRange?, settable: Set<String>) -> InputEngineFixture {
        let fixture = makeInputEngineFixture(name, frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.text = text
        fixture.axActions.selectedRange = selection
        fixture.axActions.settable = settable
        return fixture
    }

    private static let textAttributes: Set<String> = [kAXSelectedTextAttribute as String, kAXValueAttribute as String]

    func testTypeElementInsertsAtTheCaretThroughSelectedText() async throws {
        let fixture = textFieldFixture("type-ax-insert", text: "Hello world", selection: AXTextRange(location: 5, length: 0), settable: Self.textAttributes)

        let result = try await fixture.engine.type(
            TypeRequest(text: ", dear", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.text, "Hello, dear world")
        XCTAssertEqual(fixture.axActions.selectedTextWrites, [", dear"])
        XCTAssertTrue(fixture.axActions.setValues.isEmpty, "inserting never rewrites the whole value")
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(result.element?.id, "0.3")
        XCTAssertNil(result.replace)
    }

    func testTypeElementReplacesTheSelectionOnly() async throws {
        let fixture = textFieldFixture("type-ax-selection", text: "Hello world", selection: AXTextRange(location: 6, length: 5), settable: Self.textAttributes)

        let result = try await fixture.engine.type(
            TypeRequest(text: "there", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.text, "Hello there")
        XCTAssertEqual(result.verified, .checked(true))
    }

    func testTypeElementSplicesTheValueWhenSelectedTextIsIgnored() async throws {
        // Chromium accepts the AXSelectedText write and changes nothing.
        let fixture = textFieldFixture("type-ax-splice", text: "Hello world", selection: AXTextRange(location: 5, length: 0), settable: Self.textAttributes)
        fixture.axActions.selectedTextApplies = false

        let result = try await fixture.engine.type(
            TypeRequest(text: ", dear", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.setValues, ["Hello, dear world"])
        XCTAssertEqual(fixture.axActions.selectionWrites, [AXTextRange(location: 11, length: 0)], "the caret ends after the insert")
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .checked(true))
    }

    func testTypeElementReplaceWritesTheWholeValue() async throws {
        let fixture = textFieldFixture("type-ax-replace", text: "Hello world", selection: AXTextRange(location: 5, length: 0), settable: Self.textAttributes)

        let result = try await fixture.engine.type(
            TypeRequest(text: "new", delayMilliseconds: nil, inputMode: .unicode, element: "Name", replace: true)
        )

        XCTAssertEqual(fixture.axActions.setValues, ["new"])
        XCTAssertTrue(fixture.axActions.selectedTextWrites.isEmpty)
        XCTAssertEqual(fixture.axActions.text, "new")
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(result.replace, true)
    }

    func testTypeElementSecureFieldIsNeverReadBack() async throws {
        let fixture = textFieldFixture("type-ax-secure", text: nil, selection: nil, settable: Self.textAttributes)
        fixture.axActions.secure = true

        let result = try await fixture.engine.type(
            TypeRequest(text: "hunter2", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.selectedTextWrites, ["hunter2"])
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .unknown)
    }

    func testTypeElementFallsBackToKeysAtTheCaretWhenAXTextIsNotSettable() async throws {
        let caret = AXTextRange(location: 5, length: 0)
        let fixture = textFieldFixture("type-ax-fallback", text: "Hello world", selection: caret, settable: [])

        let result = try await fixture.engine.type(
            TypeRequest(text: "hello", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.focusCount, 1, "fallback should focus the element first")
        XCTAssertEqual(fixture.axActions.selectionWrites, [caret], "focusing must not move the caret the keys type at")
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["hello"])
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertEqual(
            fixture.keyboard.destinations, [.window(fixtureWindow.requiringKeyFocus())],
            "keys go to the element's own window, not the HID tap"
        )
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.inputMode, .unicode)
        XCTAssertEqual(result.verified, .unknown, "the fake keys did not change the value")
    }

    func testTypeElementReplaceFallsBackToKeysOverTheWholeValue() async throws {
        let fixture = textFieldFixture("type-ax-replace-fallback", text: "Hello", selection: AXTextRange(location: 2, length: 0), settable: [])

        let result = try await fixture.engine.type(
            TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .unicode, element: "Name", replace: true)
        )

        XCTAssertEqual(fixture.axActions.selectionWrites, [AXTextRange(location: 0, length: 5)])
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["x"])
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testTypeElementRestoresTheCaretBeforeKeysWhenAXWritesAreIgnored() async throws {
        let caret = AXTextRange(location: 2, length: 0)
        let fixture = textFieldFixture("type-ax-ignored-caret", text: "Hello", selection: caret, settable: Self.textAttributes)
        fixture.axActions.selectedTextApplies = false
        fixture.axActions.valueApplies = false

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.setValues, ["HeXllo"], "the splice was tried and ignored")
        XCTAssertEqual(fixture.axActions.selectionWrites.first, AXTextRange(location: 3, length: 0))
        XCTAssertEqual(fixture.axActions.selectedRange, caret, "keys must type at the caret the user left")
        XCTAssertFalse(fixture.axActions.selectionWrites.dropFirst().contains(AXTextRange(location: 3, length: 0)))
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["X"])
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testTypeElementByKeysIsNotVerifiedByTextThatWasAlreadyThere() async throws {
        // The keys changed nothing, but the field already held the text.
        let fixture = textFieldFixture("type-keys-already-there", text: "say hello", selection: AXTextRange(location: 0, length: 0), settable: [])

        let result = try await fixture.engine.type(
            TypeRequest(text: "hello", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.verified, .unknown)
    }

    func testTypedTextVerificationNeedsTheChangeTheTypingMade() {
        let caret = AXTextRange(location: 4, length: 0)
        func check(_ after: String?, before: String? = "say ", replace: Bool = false, text: String = "hi") -> ActionVerification {
            ScreenCommanderEngine.typedTextVerification(text: text, replace: replace, before: before, selection: caret, after: after)
        }
        XCTAssertEqual(check("say hi"), .checked(true))
        XCTAssertEqual(check("Say hi"), .checked(true), "an autocapitalized prefix still shows the insert at the caret")
        XCTAssertEqual(check("say "), .unknown, "nothing changed")
        XCTAssertEqual(check("hi say ", before: "hi say "), .unknown, "the text was already there")
        XCTAssertEqual(check("hi say x"), .unknown, "something changed, but not the insert")
        XCTAssertEqual(check(nil), .unknown)
        XCTAssertEqual(check("new", before: "old", replace: true, text: "new"), .checked(true))
        XCTAssertEqual(check("new", before: "new", replace: true, text: "new"), .unknown)
    }

    func testTypeElementChangedButUnexpectedValueIsNotTypedAgain() async throws {
        // A formatter rewrote the text: typing the keys again would duplicate it.
        let fixture = textFieldFixture("type-ax-changed", text: "12", selection: AXTextRange(location: 2, length: 0), settable: Self.textAttributes)
        fixture.axActions.formatter = { "#" + $0 }

        let result = try await fixture.engine.type(
            TypeRequest(text: "3", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(fixture.axActions.text, "#123")
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .checked(false))
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
        XCTAssertTrue(fixture.axActions.setValues.isEmpty)
    }

    private static let electronProfile = BackgroundDeliveryPolicy.profile(
        for: AppBundleClassification(toolkit: .electron, evidence: []),
        capabilities: .all,
        authenticatedKeyboardOS: true
    )

    func testTypeIntoChromiumElementsSendsKeysFirst() async throws {
        let fixture = makeInputEngineFixture("type-electron-keys-first", frontmostApp: { Self.targetApp }, profile: { _ in Self.electronProfile })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: true,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextArea", title: "Name", actions: [])]
        )
        fixture.axActions.text = "ab"
        fixture.axActions.selectedRange = AXTextRange(location: 1, length: 0)
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, element: "Name")
        )

        XCTAssertEqual(result.deliveryMethod, .focusAssisted, "a contenteditable never hears about an AX write")
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["X"])
        XCTAssertTrue(fixture.axActions.selectedTextWrites.isEmpty)
        XCTAssertTrue(fixture.axActions.setValues.isEmpty)

        let forced = try await fixture.engine.type(
            TypeRequest(text: "Y", delayMilliseconds: nil, inputMode: .unicode, element: "Name", via: .ax)
        )
        XCTAssertEqual(forced.deliveryMethod, .ax, "--via ax still writes through accessibility")
    }

    func testTypeWithoutElementInChromiumSkipsTheFocusedField() async throws {
        let fixture = makeInputEngineFixture("type-electron-bare", frontmostApp: { Self.targetApp }, profile: { _ in Self.electronProfile })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "ab"
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        )

        XCTAssertTrue(fixture.axActions.focusedTextLookups.isEmpty)
        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
    }

    func testTypeReplaceWithoutElementInChromiumSelectsTheFocusedFieldForKeys() async throws {
        let fixture = makeInputEngineFixture("type-electron-replace", frontmostApp: { Self.targetApp }, profile: { _ in Self.electronProfile })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "old text"
        fixture.axActions.selectedRange = AXTextRange(location: 3, length: 0)
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "new", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp", replace: true)
        )

        XCTAssertEqual(fixture.axActions.focusedTextLookups.map(\.pid), [77])
        XCTAssertTrue(fixture.axActions.setValues.isEmpty, "Chromium still gets key events first")
        XCTAssertEqual(fixture.axActions.selectionWrites, [AXTextRange(location: 0, length: 8)], "the keys replace the whole value")
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["new"])
        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
        XCTAssertEqual(result.replace, true)
    }

    func testKeyboardReplacementRefusesUnsafeSelectionInBareAndElementPaths() async {
        for element in [false, true] {
            for failure in ["secure", "unreadable", "failed", "ignored"] {
                let fixture = makeInputEngineFixture("type-replace-unsafe-\(element)-\(failure)", frontmostApp: { Self.targetApp }, profile: { _ in Self.electronProfile })
                fixture.targets.apps["TargetApp"] = Self.targetApp
                fixture.reader.treeResult = AXTreeResult(axPrimed: true, truncated: false, elements: [buttonRecord(id: "0.3", role: "AXTextArea", title: "Name", actions: [])])
                fixture.axActions.focusedText = AXElement.application(pid: 77)
                fixture.axActions.text = failure == "unreadable" ? nil : "old"
                fixture.axActions.selectedRange = AXTextRange(location: 3, length: 0)
                fixture.axActions.secure = failure == "secure"
                if failure == "failed" { fixture.axActions.selectionError = ScreenCommanderError.elementNotActionable("selection failed") }
                fixture.axActions.selectionApplies = failure != "ignored"
                do {
                    _ = try await fixture.engine.type(TypeRequest(text: "NEW", delayMilliseconds: nil, inputMode: .unicode,
                        element: element ? "Name" : nil, appIdentifier: "TargetApp", via: .focusAssisted, replace: true))
                    XCTFail("Expected replacement refusal for \(failure)")
                } catch {
                    XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
                }
                XCTAssertTrue(fixture.keyboard.typed.isEmpty, failure)
            }
        }
    }

    func testTypeReplaceFindsChromiumsFocusedFieldOnceItsWindowIsKey() async throws {
        // Electron reports no focused element until its window is key.
        let fixture = makeInputEngineFixture("type-electron-replace-unfocused", frontmostApp: { Self.targetApp }, profile: { _ in Self.electronProfile })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedTextAnswers = [nil]
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "old"
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "new", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp", replace: true)
        )

        let keyDestination = InputEventDestination.focusAssisted(fixtureWindow, authenticatedKeyboard: true)
        XCTAssertEqual(fixture.keyboard.prepared, [keyDestination], "looked up again while the window was held key")
        XCTAssertEqual(fixture.axActions.focusedTextLookups.count, 2)
        XCTAssertEqual(fixture.axActions.selectionWrites, [AXTextRange(location: 0, length: 3)])
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["new"])
        XCTAssertEqual(result.deliveryMethod, .focusAssisted)
    }

    func testTypeWithoutElementInsertsIntoTheFocusedTextField() async throws {
        let fixture = makeInputEngineFixture("type-focused-field", frontmostApp: { Self.targetApp })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "ab"
        fixture.axActions.selectedRange = AXTextRange(location: 1, length: 0)
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        )

        XCTAssertEqual(fixture.axActions.text, "aXb")
        XCTAssertEqual(fixture.axActions.focusedTextLookups.map(\.pid), [77])
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.verified, .checked(true))
    }

    func testTypeReportsTheModeThatDeliveredTheText() async throws {
        let fixture = makeInputEngineFixture("type-mode-reported", frontmostApp: { Self.targetApp })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "ab"
        fixture.axActions.selectedRange = AXTextRange(location: 1, length: 0)
        fixture.axActions.settable = Self.textAttributes

        let viaAX = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .paste, appIdentifier: "TargetApp")
        )
        XCTAssertEqual(viaAX.deliveryMethod, .ax)
        XCTAssertEqual(viaAX.inputMode, .ax, "an accessibility write is not a paste")
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)

        let viaKeys = try await fixture.engine.type(
            TypeRequest(text: "Y", delayMilliseconds: nil, inputMode: .paste, appIdentifier: "TargetApp", via: .window)
        )
        XCTAssertEqual(viaKeys.inputMode, .unicode)
        XCTAssertEqual(ScreenCommanderEngine.effectiveInputMode(.paste, tier: .global), .paste)
        XCTAssertEqual(ScreenCommanderEngine.effectiveInputMode(.unicode, tier: .global), .unicode)
    }

    func testUntargetedKeysGoToTheLastWindowScreenshotLikeClicks() async throws {
        let terminal = ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal")
        let terminalWindow = InputWindowTarget(pid: 12, windowID: 900, bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
        let fixture = makeInputEngineFixture("keys-follow-screenshot", frontmostApp: { terminal }, windows: [fixtureWindow, terminalWindow])
        fixture.metadataStore.seedLoad(ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z", displayID: 123,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300),
            imageSizePixels: SizeD(w: 800, h: 600), pointPixelScale: 2,
            imagePath: "/tmp/window.png", windowID: 500,
            windowBoundsPoints: RectD(x: 100, y: 200, w: 400, h: 300)
        ), at: fixture.state.lastMetadataURL)

        let key = try await fixture.engine.key(KeyRequest(chord: "a"))
        let keys = try await fixture.engine.keys(KeysRequest(steps: ["press:b"]))
        let typed = try await fixture.engine.type(TypeRequest(text: "c", delayMilliseconds: nil, inputMode: .unicode))

        let screenshotWindow = InputEventDestination.window(fixtureWindow.requiringKeyFocus())
        XCTAssertEqual(fixture.keyboard.destinations, [screenshotWindow, screenshotWindow, screenshotWindow])
        XCTAssertEqual([key.keyWindowID, keys.keyWindowID, typed.keyWindowID], [500, 500, 500])
        XCTAssertEqual(fixture.axActions.focusedTextLookups.map(\.windowID), [500], "the focused field is looked for in that window")

        // --app and --foreground keep their own targets.
        fixture.targets.apps["Terminal"] = terminal
        _ = try await fixture.engine.key(KeyRequest(chord: "d", appIdentifier: "Terminal"))
        XCTAssertEqual(fixture.keyboard.destinations.last, .window(terminalWindow))
        _ = try await fixture.engine.key(KeyRequest(chord: "e", foreground: true))
        XCTAssertEqual(fixture.keyboard.destinations.last, .global)
    }

    func testTypeWithoutElementFallsBackToKeysWithNoFocusedTextField() async throws {
        let fixture = makeInputEngineFixture("type-no-focused-field", frontmostApp: { Self.targetApp })
        fixture.targets.apps["TargetApp"] = Self.targetApp

        let result = try await fixture.engine.type(
            TypeRequest(text: "hi", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        )

        XCTAssertEqual(fixture.axActions.focusedTextLookups.count, 1)
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["hi"])
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testTypeWithoutElementFallsBackToKeysWhenTheFieldIgnoresAX() async throws {
        let fixture = makeInputEngineFixture("type-focused-ignored", frontmostApp: { Self.targetApp })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "ab"
        fixture.axActions.settable = [kAXSelectedTextAttribute as String]
        fixture.axActions.selectedTextApplies = false

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        )

        XCTAssertEqual(fixture.axActions.text, "ab")
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["X"])
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testTypeForcedKeyTierSkipsTheFocusedField() async throws {
        let fixture = makeInputEngineFixture("type-via-window", frontmostApp: { Self.targetApp })
        fixture.targets.apps["TargetApp"] = Self.targetApp
        fixture.axActions.focusedText = AXElement.application(pid: 77)
        fixture.axActions.text = "ab"
        fixture.axActions.settable = Self.textAttributes

        let result = try await fixture.engine.type(
            TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp", via: .window)
        )

        XCTAssertTrue(fixture.axActions.focusedTextLookups.isEmpty)
        XCTAssertEqual(fixture.axActions.text, "ab")
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testTypeViaAXWithoutAFocusedFieldOrReplaceWithoutAFieldFails() async {
        let fixture = makeInputEngineFixture("type-via-ax-no-field", frontmostApp: { Self.targetApp })

        await assertThrows(
            try await fixture.engine.type(TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .unicode, via: .ax))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
        }
        await assertThrows(
            try await fixture.engine.type(TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .unicode, replace: true))
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
        }
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
    }

    func testForegroundTypeDefaultsToKeyEventsNotThePasteboard() async throws {
        let fixture = makeInputEngineFixture("type-foreground-default", frontmostApp: { Self.targetApp })

        let defaults = try TypeCommand.parse(["hi"])
        XCTAssertEqual(defaults.mode, .unicode, "the CLI default never uses the clipboard")
        let result = try await fixture.engine.type(
            TypeRequest(text: "hi", delayMilliseconds: nil, inputMode: defaults.mode, foreground: true)
        )

        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertEqual(fixture.keyboard.typed.map(\.text), ["hi"])
        XCTAssertEqual(fixture.keyboard.destinations, [.global])
        XCTAssertEqual(result.inputMode, .unicode)

        _ = try await fixture.engine.type(
            TypeRequest(text: "pasted", delayMilliseconds: nil, inputMode: .paste, foreground: true)
        )
        XCTAssertEqual(fixture.keyboard.pasted, ["pasted"], "paste runs only when asked for")
    }

    func testTypeElementDoesNotKeyboardFallbackWhenFocusFails() async {
        let fixture = makeInputEngineFixture("wp5-type-focus-fails", frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.setValueError = ScreenCommanderError.elementNotActionable("AXValue is read-only here")
        fixture.axActions.focusError = ScreenCommanderError.elementNotActionable("AXFocused rejected")

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "hello", delayMilliseconds: nil, inputMode: .paste, element: "Name")
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
        }
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertTrue(fixture.keyboard.typed.isEmpty)
    }

    func testTypeRejectsGlobalWithoutForegroundAndBareViaAX() async {
        let fixture = makeInputEngineFixture("wp5-type-invalid-via", frontmostApp: { Self.targetApp })

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, element: "Name", via: .global)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable",
                           "a bare --via ax needs a focused text field")
        }
    }

    func testTypeElementForcedViaAXFailureThrows72() async {
        let fixture = makeInputEngineFixture("wp5-type-via-ax-strict", frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [])]
        )
        fixture.axActions.setValueError = ScreenCommanderError.elementNotActionable("AXValue is read-only here")

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, element: "Name", via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty, "--via ax must not fall back to the keyboard")
    }

    func testTypeElementDisabledThrows72WithoutKeyboardFallback() async {
        let fixture = makeInputEngineFixture("wp5-type-disabled", frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.3", role: "AXTextField", title: "Name", actions: [], enabled: false)]
        )

        await assertThrows(
            try await fixture.engine.type(
                TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .paste, element: "Name")
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "element_not_actionable")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 72)
        }
        XCTAssertTrue(fixture.keyboard.pasted.isEmpty)
        XCTAssertEqual(fixture.axActions.focusCount, 0)
    }

    func testElementScrollUsesWindowTierThenFocusAssisted() async throws {
        let fixture = makeInputEngineFixture("wp5-scroll-element", frontmostApp: { Self.targetApp })
        fixture.reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [buttonRecord(id: "0.5", role: "AXScrollArea", title: "Content", actions: [])]
        )

        let result = try await fixture.engine.scroll(
            ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content")
        )

        let call = try XCTUnwrap(fixture.mouse.scrollCalls.first)
        XCTAssertEqual(call.destination, .window(fixtureWindow))
        XCTAssertEqual(call.point, CGPoint(x: 120, y: 210))
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.element?.id, "0.5")

        // A window-tier failure downgrades to focusAssisted (recorded, not an error).
        let fallbackFixture = makeInputEngineFixture("wp5-scroll-element-fallback", frontmostApp: { Self.targetApp })
        fallbackFixture.reader.treeResult = fixture.reader.treeResult
        fallbackFixture.mouse.windowScrollError = ScreenCommanderError.inputSynthesisFailed("window post rejected")

        let fallback = try await fallbackFixture.engine.scroll(
            ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content")
        )
        XCTAssertEqual(fallbackFixture.mouse.scrollCalls.first?.destination, .focusAssisted(fixtureWindow, authenticatedKeyboard: false))
        XCTAssertEqual(fallback.deliveryMethod, .focusAssisted)
    }

    func testElementScrollRejectsAXTier() async {
        let fixture = makeInputEngineFixture("wp5-scroll-via-ax", frontmostApp: { Self.targetApp })

        await assertThrows(
            try await fixture.engine.scroll(
                ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -3, unit: .lines, element: "Content", via: .ax)
            )
        ) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
    }

    func testSequenceDecodesElementClickAndTypeSteps() throws {
        let data = Data("""
        {"steps":[
            {"click":{"element":"Save","role":"button","app":"TargetApp","via":"ax","noCursor":true,"strict":true}},
            {"click":{"elementId":"0.3.2","windowId":42,"foreground":true,"via":"pid"}},
            {"type":{"text":"hi","element":"Name","via":"ax"}},
            {"key":{"chord":"cmd+s","app":"TargetApp","windowId":7,"foreground":false}},
            {"drag":{"x1":1,"y1":2,"x2":3,"y2":4,"app":"TargetApp","foreground":true}},
            {"move":{"x":1,"y":2,"windowId":9}},
            {"scroll":{"x":1,"y":2,"dy":1,"windowId":5,"foreground":true}}
        ]}
        """.utf8)
        let file = try JSONDecoder().decode(SequenceFile.self, from: data)

        guard case .click(let click) = file.steps[0] else {
            return XCTFail("Expected click step.")
        }
        XCTAssertNil(click.x)
        XCTAssertEqual(click.element, "Save")
        XCTAssertEqual(click.role, "button")
        XCTAssertEqual(click.app, "TargetApp")
        XCTAssertEqual(click.via, .ax)
        XCTAssertEqual(click.noCursor, true)
        XCTAssertEqual(click.strict, true)

        guard case .click(let byID) = file.steps[1] else {
            return XCTFail("Expected click step.")
        }
        XCTAssertEqual(byID.elementId, "0.3.2")
        XCTAssertEqual(byID.windowId, 42)
        XCTAssertEqual(byID.foreground, true)
        XCTAssertEqual(byID.via, .window, "the pre-1.0 'pid' spelling decodes as window")

        guard case .key(let key) = file.steps[3],
              case .drag(let drag) = file.steps[4],
              case .move(let move) = file.steps[5],
              case .scroll(let scroll) = file.steps[6] else {
            return XCTFail("Expected key, drag, move, and scroll steps.")
        }
        XCTAssertEqual(key.app, "TargetApp")
        XCTAssertEqual(key.windowId, 7)
        XCTAssertEqual(key.foreground, false)
        XCTAssertEqual(drag.app, "TargetApp")
        XCTAssertEqual(drag.foreground, true)
        XCTAssertEqual(move.windowId, 9)
        XCTAssertEqual(scroll.windowId, 5)
        XCTAssertEqual(scroll.foreground, true)

        guard case .type(let type) = file.steps[2] else {
            return XCTFail("Expected type step.")
        }
        XCTAssertEqual(type.element, "Name")
        XCTAssertEqual(type.via, .ax)
    }

    // MARK: - observe

    private final class EventCollector: @unchecked Sendable {
        var events: [ObservedEvent] = []
    }

    private func makeObserveEngine(
        stateName: String,
        permissions: FakePermissions = FakePermissions(),
        targets: FakeTargets,
        reader: FakeAccessibilityReader = FakeAccessibilityReader(),
        source: FakeObservationSource
    ) -> ScreenCommanderEngine {
        let state = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": tempStatePath(stateName).path])
        let metadataStore = FakeMetadataStore(defaultLastMetadataURL: state.lastMetadataURL)
        return ScreenCommanderEngine(
            permissions: permissions,
            displays: NoopDisplays(),
            capturer: FakeCapturer(
                captureResult: CapturedScreenshot(
                    image: make1x1Image(),
                    displayID: 1,
                    displayBoundsPoints: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pointPixelScale: 1
                )
            ),
            imageWriter: FakeImageWriter(returnedSize: SizeD(w: 1, h: 1)),
            metadataStore: metadataStore,
            coordinateMapper: CoordinateMapper(),
            mouseController: FakeMouseController(),
            keyboardController: FakeKeyboardController(),
            retention: FakeRetentionManager(),
            accessibilityReader: reader,
            targets: targets,
            observationSource: source,
            frontmostApp: { nil },
            statePaths: state,
            fileManager: .default
        )
    }

    private func event(_ kind: ObservedEventKind, _ name: String, element: AXElementRecord? = nil) -> ObservedEvent {
        ObservedEvent(
            ts: "2026-07-06T12:00:00.000Z",
            kind: kind,
            event: name,
            app: ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil),
            element: element
        )
    }

    func testObserveResolvesAppChecksPermissionAndForwardsKinds() async throws {
        let permissions = FakePermissions()
        let targets = FakeTargets()
        let app = ResolvedApp(pid: 42, name: "TextEdit", bundleID: "com.apple.TextEdit")
        targets.apps["TextEdit"] = app
        let source = FakeObservationSource()
        source.scriptedEvents = []

        let engine = makeObserveEngine(stateName: "observe-resolve", permissions: permissions, targets: targets, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", kinds: [.value, .focus])
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(permissions.accessibilityChecks, 1)
        XCTAssertEqual(targets.resolveCalls, ["TextEdit"])
        XCTAssertEqual(source.requestedApp, app)
        XCTAssertEqual(source.requestedKinds, [.value, .focus])
    }

    func testObserveFiltersEmittedEventsByKind() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.scriptedEvents = [
            event(.value, "value_changed"),
            event(.app, "app_activated"),
            event(.focus, "focus_changed")
        ]

        let engine = makeObserveEngine(stateName: "observe-filter", targets: targets, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", kinds: [.value, .focus])
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(collector.events.map(\.event), ["value_changed", "focus_changed"])
    }

    func testObserveUntilMatchesIncomingEvent() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let matching = AXElementRecord(id: "0.1", role: "AXButton", title: "Save File")
        let source = FakeObservationSource()
        source.scriptedEvents = [
            event(.value, "value_changed", element: AXElementRecord(id: "0.0", role: "AXTextField", title: "Body")),
            event(.value, "value_changed", element: matching),
            event(.value, "value_changed", element: AXElementRecord(id: "0.2", role: "AXButton", title: "Cancel"))
        ]
        // Initial scan finds nothing.
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [])

        let engine = makeObserveEngine(stateName: "observe-until", targets: targets, reader: reader, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "TextEdit",
                predicate: try ObservePredicate.parse("role=AXButton title~=Save")
            )
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .matched(matching))
        // Emission stops at the matching event; the trailing Cancel event is not emitted.
        XCTAssertEqual(collector.events.count, 2)
        XCTAssertEqual(collector.events.last?.element, matching)
    }

    func testObserveInitialScanMatchesImmediately() async throws {
        let targets = FakeTargets()
        targets.apps["Finder"] = ResolvedApp(pid: 99, name: "Finder", bundleID: nil)
        let existing = AXElementRecord(id: "0.3", role: "AXWindow", title: "Downloads")
        let reader = FakeAccessibilityReader()
        reader.treeResult = AXTreeResult(
            axPrimed: false,
            truncated: false,
            elements: [AXElementRecord(id: "0", role: "AXApplication"), existing]
        )
        let source = FakeObservationSource()
        source.scriptedEvents = [event(.window, "window_created")]

        let engine = makeObserveEngine(stateName: "observe-initial", targets: targets, reader: reader, source: source)
        let collector = EventCollector()

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "Finder",
                predicate: try ObservePredicate.parse("role=AXWindow title~=Downloads")
            )
        ) { event in
            collector.events.append(event)
        }

        XCTAssertEqual(outcome, .matched(existing))
        // Already-true condition returns before the live source is ever consulted.
        XCTAssertTrue(collector.events.isEmpty)
        XCTAssertNil(source.requestedApp)
    }

    func testObserveTimeoutWithUntilReturns73Outcome() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.keepOpen = true // never yields, never finishes → timeout wins

        let engine = makeObserveEngine(stateName: "observe-timeout-until", targets: targets, source: source)

        let outcome = try await engine.observe(
            ObserveRequest(
                appIdentifier: "TextEdit",
                timeoutMS: 50,
                predicate: try ObservePredicate.parse("role=AXButton")
            )
        ) { _ in }

        XCTAssertEqual(outcome, .timedOutUnmet)
    }

    func testObservePlainTimeoutReturnsTimedOut() async throws {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        source.keepOpen = true

        let engine = makeObserveEngine(stateName: "observe-timeout-plain", targets: targets, source: source)

        let outcome = try await engine.observe(
            ObserveRequest(appIdentifier: "TextEdit", timeoutMS: 50)
        ) { _ in }

        XCTAssertEqual(outcome, .timedOut)
    }

    func testObserveRejectsNegativeTimeout() async {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let engine = makeObserveEngine(stateName: "observe-neg-timeout", targets: targets, source: FakeObservationSource())

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit", timeoutMS: -1)) { _ in }
            XCTFail("Expected invalid_arguments")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "invalid_arguments")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testObserveDeniedAccessibilityStopsBeforeResolvingApp() async {
        let permissions = FakePermissions()
        permissions.allowAccessibility = false
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()

        let engine = makeObserveEngine(stateName: "observe-denied", permissions: permissions, targets: targets, source: source)

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit")) { _ in }
            XCTFail("Expected permission error")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "permission_denied_accessibility")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(targets.resolveCalls.isEmpty)
        XCTAssertNil(source.requestedApp)
    }

    func testObserveSurfacesObserverSetupFailure() async {
        let targets = FakeTargets()
        targets.apps["TextEdit"] = ResolvedApp(pid: 42, name: "TextEdit", bundleID: nil)
        let source = FakeObservationSource()
        // No `--until`, so the source (not the initial scan) is consulted; it fails
        // setup instead of finishing cleanly.
        source.setupError = ScreenCommanderError.axTreeUnavailable("no observer")

        let engine = makeObserveEngine(stateName: "observe-setup-fail", targets: targets, source: source)

        do {
            _ = try await engine.observe(ObserveRequest(appIdentifier: "TextEdit", kinds: [.value])) { _ in }
            XCTFail("Expected ax_tree_unavailable")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "ax_tree_unavailable")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Presence integration

/// A presence process for engine tests. Records every call in order, keeps its
/// bookkeeping in a real `PresenceState` on a fake clock, and gives this engine
/// one connection that lives until `disconnect()`, like the real client. Other
/// agents' leases sit on connections of their own. Thread-safe.
private final class FakePresence: PresenceControlling, @unchecked Sendable {
    enum Call: Equatable {
        case acquire(session: String, pid: pid_t)
        case status
        /// `statusIfRunning`: a status check that never starts presence.
        case probe
        case setState(session: String, state: CursorState)
        case move(session: String, point: PresencePoint, windowID: UInt32?)
        /// `delivered`: how many input deliveries had happened when the call arrived.
        case guardBegin(pid: pid_t, delivered: Int)
        case guardRenew(pid: pid_t, delivered: Int)
        case press(session: String, count: Int, delivered: Int)
        case guardEnd(pid: pid_t)
    }

    static let enginePID: pid_t = 4_242

    private let lock = NSLock()
    private var log: [Call] = []
    private var state = PresenceState()
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private var connection: PresenceConnectionID?
    private var nextConnection: PresenceConnectionID = 1
    private var activeStatuses = 0
    private var _connectedAtDelivery: Int?
    private var _lastAcquire: (holdMs: Int, idleMs: Int, lingerMs: Int)?

    let isEnabled = true
    /// False models a presence process that cannot be reached.
    var available = true
    /// False models a presence process that is not running: `statusIfRunning`
    /// answers unavailable, and the first call that may start it does.
    var running = true
    var aborted = false
    /// Restores the focus guard reports in `status`.
    var guardRestores: [GuardRestoreStatus]?
    /// Counts input deliveries, so calls can be placed relative to delivery.
    var deliveries: () -> Int = { 0 }
    /// When set, `moveCursor` waits on it (serialization tests).
    var moveGate: WindowResolutionGate?
    var onMove: (() async -> Void)?
    private(set) var launchPreviousPID: pid_t?
    /// When set, `acquire` waits on it (serialization tests).
    var acquireGate: WindowResolutionGate?

    var calls: [Call] {
        withLock { log }
    }

    /// How many deliveries had happened when this engine first connected, which
    /// is when presence learned its pid. Nil when it never connected.
    var connectedAtDelivery: Int? {
        withLock { _connectedAtDelivery }
    }

    var lastAcquire: (holdMs: Int, idleMs: Int, lingerMs: Int)? {
        withLock { _lastAcquire }
    }

    var snapshot: PresenceState {
        withLock { state }
    }

    var guardRemaining: TimeInterval? {
        withLock { state.guards[77].map { $0.expiresAt.timeIntervalSince(clock) } }
    }

    /// The next `count` status checks report the user active in the session.
    func reportUserActive(forChecks count: Int) {
        withLock { activeStatuses = count }
    }

    /// Another agent's session takes the lease on its own connection.
    func leaseHeld(by session: String, pid: pid_t, idleMs: Int = 600_000) {
        withLock {
            let other = nextConnection
            nextConnection += 1
            state.openConnection(other, peerPID: 7_000 + pid_t(other))
            _ = state.acquire(session: session, targetPID: pid, holdMs: 0, idleMs: idleMs, connection: other, now: clock)
        }
    }

    /// Moves the fake clock and runs the presence process's housekeeping.
    func advance(_ seconds: TimeInterval) {
        withLock {
            clock = clock.addingTimeInterval(seconds)
            _ = state.sweep(now: clock, isProcessAlive: { _ in true })
        }
    }

    /// Real user input reaching `pid`: a key press or click (`deliberate`), or
    /// pointer motion anywhere (`ambient`).
    func userInput(to pid: pid_t?, kind: UserInputKind = .deliberate, source: pid_t = 0) {
        withLock {
            _ = state.recordUserInput(sourcePID: source, targetPID: pid, kind: kind, isAbortChord: false, ownPID: 1, now: clock)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func record(_ call: Call) {
        withLock { log.append(call) }
    }

    /// Caller holds the lock. Opens this engine's connection, which registers its pid.
    private func connect() -> PresenceConnectionID {
        if let connection {
            return connection
        }
        let id = nextConnection
        nextConnection += 1
        state.openConnection(id, peerPID: Self.enginePID)
        connection = id
        running = true
        if _connectedAtDelivery == nil {
            _connectedAtDelivery = deliveries()
        }
        return id
    }

    func acquire(session: String, pid: pid_t, holdMs: Int, idleMs: Int, lingerMs: Int) async -> PresenceReply<LeaseResult> {
        record(.acquire(session: session, pid: pid))
        if let acquireGate {
            await acquireGate.wait()
        }
        guard available else { return .unavailable("fake: unreachable") }
        return withLock {
            let id = connect()
            _lastAcquire = (holdMs, idleMs, lingerMs)
            if aborted {
                return .failure(PresenceError(code: .abortedByUser, message: "Stopped by the user."))
            }
            switch state.acquire(session: session, targetPID: pid, holdMs: holdMs, idleMs: idleMs, lingerMs: lingerMs, connection: id, now: clock) {
            case .success(let lease): return .success(lease)
            case .failure(let error): return .failure(error)
            }
        }
    }

    private func currentStatus() -> PresenceStatus {
        withLock {
            let active = activeStatuses > 0
            if activeStatuses > 0 && activeStatuses != Int.max {
                activeStatuses -= 1
            }
            let sessions = state.sessionStatuses(now: clock).map { status -> SessionStatus in
                var status = status
                if active {
                    status.userActive = true
                    status.lastUserInputMsAgo = 200
                }
                return status
            }
            return PresenceStatus(
                protocolVersion: PresenceProtocol.version,
                serverPID: 999,
                aborted: aborted,
                tapAvailable: true,
                overlayWindowIDs: [],
                sessions: sessions,
                guardedPIDs: [],
                guardRestores: guardRestores,
                lastUserInputMsAgo: state.lastUserInputMsAgo(now: clock),
                appInput: state.appInputStatuses(now: clock)
            )
        }
    }

    func status() async -> PresenceReply<PresenceStatus> {
        record(.status)
        guard available else { return .unavailable("fake: unreachable") }
        withLock { _ = connect() }
        return .success(currentStatus())
    }

    func statusIfRunning() async -> PresenceReply<PresenceStatus> {
        record(.probe)
        guard available, withLock({ running }) else { return .unavailable("fake: not running") }
        withLock { _ = connect() }
        return .success(currentStatus())
    }

    func setCursorState(session: String, state cursorState: CursorState) async -> PresenceReply<PresenceEmpty> {
        record(.setState(session: session, state: cursorState))
        guard available else { return .unavailable("fake: unreachable") }
        withLock { state.setCursorState(cursorState, session: session, connection: connect(), now: clock) }
        return .success(PresenceEmpty())
    }

    func moveCursor(session: String, to point: PresencePoint, windowID: UInt32?) async -> PresenceReply<CursorMoveResult> {
        record(.move(session: session, point: point, windowID: windowID))
        if let moveGate {
            await moveGate.wait()
        }
        await onMove?()
        guard available else { return .unavailable("fake: unreachable") }
        return .success(CursorMoveResult(session: session, point: point, arrived: true, visible: true, cursorWindowID: 9_000))
    }

    func pressCursor(session: String, count: Int) async -> PresenceReply<PresenceEmpty> {
        record(.press(session: session, count: count, delivered: deliveries()))
        return available ? .success(PresenceEmpty()) : .unavailable("fake: unreachable")
    }

    func beginGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> {
        record(.guardBegin(pid: pid, delivered: deliveries()))
        guard available else { return .unavailable("fake: unreachable") }
        return withLock {
            state.noteActed(session: session, targetPID: pid, now: clock)
            switch state.beginGuard(targetPID: pid, leaseMs: leaseMs, frontmostPID: 12, now: clock) {
            case .success(let guardResult): return .success(guardResult)
            case .failure(let error): return .failure(error)
            }
        }
    }

    func renewGuard(pid: pid_t, leaseMs: Int, session: String) async -> PresenceReply<GuardResult> {
        record(.guardRenew(pid: pid, delivered: deliveries()))
        guard available else { return .unavailable("fake: unreachable") }
        return withLock {
            switch state.beginGuard(targetPID: pid, leaseMs: leaseMs, frontmostPID: 12, now: clock, renew: true) {
            case .success(let result): return .success(result)
            case .failure(let error): return .failure(error)
            }
        }
    }

    func beginLaunchGuard(pid: pid_t, leaseMs: Int, session: String, previousFrontmostPID: pid_t?) async -> PresenceReply<GuardResult> {
        launchPreviousPID = previousFrontmostPID
        return await beginGuard(pid: pid, leaseMs: leaseMs, session: session)
    }

    func endGuard(pid: pid_t) async {
        record(.guardEnd(pid: pid))
    }

    /// The engine's connection closes, as when its process exits.
    func disconnect() {
        withLock {
            if let connection {
                state.closeConnection(connection, now: clock)
            }
            connection = nil
        }
    }
}

/// A focus sampler safe to share between concurrent actions.
private final class LockedFocusSampler: FocusSampling, @unchecked Sendable {
    private let lock = NSLock()

    func sample() -> FocusSample {
        lock.lock()
        defer { lock.unlock() }
        return FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 5, y: 5))
    }

    func settle() {}
}

/// Records requested waits instead of sleeping.
private final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var waits: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sleep(_ seconds: TimeInterval) async {
        record(seconds)
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        recorded.append(seconds)
        lock.unlock()
    }
}

final class PresenceIntegrationTests: XCTestCase {
    /// Pixel (200, 100) on the fixture display maps to global point (200, 250),
    /// inside the fixture window.
    private static let clickPoint = PresencePoint(x: 200, y: 250)

    private func clickRequest(session: String? = nil, agentCursor: Bool? = nil, foreground: Bool = false, double: Bool = false) -> ClickRequest {
        ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: double, triple: false,
            primeClick: false, humanLike: true, modifiers: [],
            foreground: foreground, session: session, agentCursor: agentCursor
        )
    }

    private func makeFixture(
        _ name: String,
        presence: FakePresence,
        settings: PresenceSettings = PresenceSettings(defaultSession: "default", cursorEnabled: true),
        policy: PresencePolicy = PresencePolicy(),
        focusSampler: FocusSampling? = nil
    ) -> InputEngineFixture {
        let fixture = makeInputEngineFixture(
            name,
            frontmostApp: { ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal") },
            presence: presence,
            presenceSettings: settings,
            presencePolicy: policy,
            focusSampler: focusSampler
        )
        let mouse = fixture.mouse
        let keyboard = fixture.keyboard
        presence.deliveries = { mouse.allDestinations.count + keyboard.destinations.count }
        fixture.targets.apps["TargetApp"] = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
        return fixture
    }

    private func assertCode(_ error: Error, _ code: String, _ exitCode: Int32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, code, file: file, line: line)
        XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, exitCode, file: file, line: line)
    }

    // MARK: Flow

    func testClickLeasesChecksGlidesGuardsDeliversThenPresses() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-flow-click", presence: presence)

        let result = try await fixture.engine.click(clickRequest(double: true))

        XCTAssertEqual(presence.calls, [
            .acquire(session: "default", pid: 77),
            .status,
            .move(session: "default", point: Self.clickPoint, windowID: 500),
            .guardBegin(pid: 77, delivered: 0), .acquire(session: "default", pid: 77), .probe,
            .press(session: "default", count: 2, delivered: 1),
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 1),
            // The receipt asks whether the focus guard restored focus meanwhile.
            .status,
        ])
        XCTAssertEqual(result.presence, .active)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .window(fixtureWindow))
    }

    func testAbortDuringSuccessfulCursorMovePostsNoInput() async {
        let presence = FakePresence()
        presence.onMove = { presence.aborted = true }
        let fixture = makeFixture("presence-abort-during-glide", presence: presence)
        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected aborted_by_user")
        } catch { assertCode(error, "aborted_by_user", 53) }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testLeaseLostDuringGlideStopsBeforePosting() async {
        let presence = FakePresence()
        var policy = PresencePolicy()
        policy.leaseIdleMs = 500
        presence.onMove = {
            presence.advance(0.6)
            presence.leaseHeld(by: "other", pid: 77)
        }
        let fixture = makeFixture("presence-lost-lease-during-glide", presence: presence, policy: policy)
        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected target_busy")
        } catch { assertCode(error, "target_busy", 52) }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testShortLeaseIsRenewedThroughoutCursorMotion() async throws {
        let presence = FakePresence()
        var policy = PresencePolicy()
        policy.leaseIdleMs = 500
        presence.onMove = {
            for tick in 1...8 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                presence.advance(0.1)
                if tick == 6 {
                    presence.leaseHeld(by: "other", pid: 77)
                    XCTAssertEqual(presence.snapshot.leases[77]?.session, "default")
                }
            }
        }
        let fixture = makeFixture("presence-renew-glide", presence: presence, policy: policy)
        _ = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(fixture.mouse.calls.count, 1)
        XCTAssertEqual(presence.snapshot.leases[77]?.session, "default")
    }

    func testShortLeaseIsRenewedThroughoutBackgroundAndForegroundYield() async throws {
        for foreground in [false, true] {
            let presence = FakePresence()
            var policy = PresencePolicy()
            policy.leaseIdleMs = 500
            presence.reportUserActive(forChecks: 1)
            policy.sleep = { _ in
                for tick in 1...8 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    presence.advance(0.1)
                    if tick == 6 {
                        presence.leaseHeld(by: "other", pid: 77)
                        XCTAssertEqual(presence.snapshot.leases[77]?.session, "default")
                    }
                }
            }
            let fixture = makeFixture("presence-renew-yield-\(foreground)", presence: presence, policy: policy)
            _ = try await fixture.engine.type(TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode,
                                                        appIdentifier: "TargetApp", foreground: foreground))
            XCTAssertEqual(fixture.keyboard.typed.count, 1)
        }
    }

    func testLongTypingRenewsLeaseAndGuardThenLeavesFullGuardPeriod() async throws {
        let presence = FakePresence()
        var policy = PresencePolicy()
        policy.leaseIdleMs = 500
        policy.guardLeaseMs = 300
        let fixture = makeFixture("presence-renew-long-type", presence: presence, policy: policy)
        fixture.keyboard.onType = {
            for tick in 1...8 {
                Thread.sleep(forTimeInterval: 0.1)
                presence.advance(0.1)
                XCTAssertGreaterThan(presence.guardRemaining ?? 0, 0, "guard stays active during delivery")
                if tick == 6 {
                    presence.leaseHeld(by: "other", pid: 77)
                    XCTAssertEqual(presence.snapshot.leases[77]?.session, "default")
                }
            }
        }
        _ = try await fixture.engine.type(TypeRequest(text: "X", delayMilliseconds: nil, inputMode: .unicode,
                                                    appIdentifier: "TargetApp"))
        XCTAssertGreaterThanOrEqual(presence.guardRemaining ?? 0, 0.299)
        XCTAssertEqual(fixture.keyboard.typed.count, 1)
    }

    func testKeyboardActionsSkipTheGlideAndPress() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-flow-keys", presence: presence)

        let key = try await fixture.engine.key(KeyRequest(chord: "cmd+s", appIdentifier: "TargetApp"))
        let typed = try await fixture.engine.type(TypeRequest(text: "a", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp"))

        XCTAssertEqual(presence.calls, [
            .acquire(session: "default", pid: 77), .status, .guardBegin(pid: 77, delivered: 0), .acquire(session: "default", pid: 77), .probe,
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 1), .status,
            .acquire(session: "default", pid: 77), .status, .setState(session: "default", state: .idle),
            .guardBegin(pid: 77, delivered: 1), .acquire(session: "default", pid: 77), .probe,
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 2), .status,
        ])
        XCTAssertEqual(key.presence, .active)
        XCTAssertEqual(typed.presence, .active)
    }

    func testDragGlidesToTheStartThenFollowsToTheEnd() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-flow-drag", presence: presence)

        let result = try await fixture.engine.drag(DragRequest(
            x1: 200, y1: 100, x2: 300, y2: 200, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, steps: 2, durationMS: 0
        ))

        let moves = presence.calls.compactMap { call -> PresencePoint? in
            if case .move(_, let point, _) = call { return point }
            return nil
        }
        XCTAssertEqual(moves, [Self.clickPoint, PresencePoint(x: 250, y: 300)])
        XCTAssertFalse(presence.calls.contains { if case .press = $0 { return true } else { return false } })
        XCTAssertEqual(result.presence, .active)
    }

    func testScrollAndMoveGlideWithoutPress() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-flow-scroll-move", presence: presence)

        let scroll = try await fixture.engine.scroll(ScrollRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -1, unit: .lines
        ))
        let move = try await fixture.engine.move(MoveRequest(x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil, dwellMS: 0))

        XCTAssertEqual(presence.calls.filter { if case .move = $0 { return true } else { return false } }.count, 2)
        XCTAssertFalse(presence.calls.contains { if case .press = $0 { return true } else { return false } })
        XCTAssertEqual(scroll.presence, .active)
        XCTAssertEqual(move.presence, .active)
    }

    // MARK: Leases, abort, yield

    func testAnotherSessionsLeaseFailsWithTargetBusyBeforeDelivery() async {
        let presence = FakePresence()
        presence.leaseHeld(by: "agent-b", pid: 77)
        let fixture = makeFixture("presence-target-busy", presence: presence)

        do {
            _ = try await fixture.engine.click(clickRequest(session: "agent-a"))
            XCTFail("Expected target_busy")
        } catch {
            assertCode(error, "target_busy", 52)
        }
        XCTAssertEqual(presence.calls, [.acquire(session: "agent-a", pid: 77)])
        XCTAssertTrue(fixture.mouse.calls.isEmpty)

        // The holder itself keeps working.
        let result = try? await fixture.engine.click(clickRequest(session: "agent-b"))
        XCTAssertEqual(result?.presence, .active)
    }

    func testAbortStopsInputUntilResume() async throws {
        let presence = FakePresence()
        presence.aborted = true
        let fixture = makeFixture("presence-abort", presence: presence)

        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected aborted_by_user")
        } catch {
            assertCode(error, "aborted_by_user", 53)
        }
        do {
            _ = try await fixture.engine.keys(KeysRequest(steps: ["press:a"], appIdentifier: "TargetApp"))
            XCTFail("Expected aborted_by_user")
        } catch {
            assertCode(error, "aborted_by_user", 53)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
        XCTAssertFalse(presence.calls.contains { if case .move = $0 { return true } else { return false } })

        presence.aborted = false
        let result = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(result.presence, .active)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testUserActiveWaitsWithPausedCursorThenDelivers() async throws {
        let presence = FakePresence()
        presence.leaseHeld(by: "default", pid: 77)
        presence.reportUserActive(forChecks: 2)
        let sleeper = RecordingSleeper()
        var policy = PresencePolicy()
        policy.sleep = sleeper.sleep
        let fixture = makeFixture("presence-yield-proceeds", presence: presence, policy: policy)

        let result = try await fixture.engine.click(clickRequest())

        XCTAssertEqual(presence.calls, [
            .acquire(session: "default", pid: 77),
            .status,
            .setState(session: "default", state: .paused),
            .status,
            .status,
            .setState(session: "default", state: .idle),
            .move(session: "default", point: Self.clickPoint, windowID: 500),
            .guardBegin(pid: 77, delivered: 0), .acquire(session: "default", pid: 77), .probe,
            .press(session: "default", count: 1, delivered: 1),
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 1),
            .status,
        ])
        // The user's last input was 200 ms ago and the quiet period is 1 s.
        XCTAssertEqual(sleeper.waits.count, 2)
        XCTAssertEqual(sleeper.waits.first ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.presence, .active)
    }

    func testLoadingCursorReturnsToIdleBeforeTheNextGlide() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-loading-cycle", presence: presence)

        _ = try await fixture.engine.click(clickRequest())
        let afterFirst = presence.calls.count
        _ = try await fixture.engine.click(clickRequest())

        XCTAssertEqual(presence.calls.prefix(afterFirst).dropLast(2).last, .setState(session: "default", state: .loading),
                       "after a successful action the agent is deciding its next step")
        XCTAssertEqual(presence.calls.prefix(afterFirst).last, .status, "the receipt's focus-guard check")
        XCTAssertEqual(Array(presence.calls.dropFirst(afterFirst)), [
            .acquire(session: "default", pid: 77),
            .status,
            .setState(session: "default", state: .idle),
            .move(session: "default", point: Self.clickPoint, windowID: 500),
            .guardBegin(pid: 77, delivered: 1), .acquire(session: "default", pid: 77), .probe,
            .press(session: "default", count: 1, delivered: 2),
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 2),
            .status,
        ])
    }

    func testFailedActionLeavesTheCursorIdle() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-loading-failure", presence: presence)
        _ = try await fixture.engine.click(clickRequest())

        let failure = ScreenCommanderError.backgroundDeliveryUnavailable("fake: no tier")
        fixture.mouse.windowClickError = failure
        fixture.mouse.focusAssistedClickError = failure
        fixture.mouse.globalClickError = failure
        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected the click to fail")
        } catch {}

        let states = presence.calls.compactMap { call -> CursorState? in
            if case .setState(_, let state) = call { return state }
            return nil
        }
        XCTAssertEqual(states, [.loading, .idle], "the failed action resets the cursor and never sets loading")
    }

    func testNoAgentCursorNeverSetsLoadingButClearsAnEarlierOne() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-loading-no-cursor", presence: presence)

        _ = try await fixture.engine.click(clickRequest())
        _ = try await fixture.engine.click(clickRequest(agentCursor: false))
        _ = try await fixture.engine.click(clickRequest(agentCursor: false))

        let states = presence.calls.compactMap { call -> CursorState? in
            if case .setState(_, let state) = call { return state }
            return nil
        }
        XCTAssertEqual(states, [.loading, .idle])
    }

    func testUnreachablePresenceSetsNoCursorState() async throws {
        let presence = FakePresence()
        presence.available = false
        let fixture = makeFixture("presence-loading-unavailable", presence: presence)

        _ = try await fixture.engine.click(clickRequest())
        _ = try await fixture.engine.click(clickRequest())

        XCTAssertFalse(presence.calls.contains { if case .setState = $0 { return true } else { return false } })
    }

    func testUserWhoKeepsWorkingFailsWithUserInterrupted() async {
        let presence = FakePresence()
        presence.leaseHeld(by: "default", pid: 77)
        presence.reportUserActive(forChecks: Int.max)
        let sleeper = RecordingSleeper()
        var policy = PresencePolicy()
        policy.sleep = sleeper.sleep
        policy.userYieldTimeout = 2
        let fixture = makeFixture("presence-yield-interrupted", presence: presence, policy: policy)

        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected user_interrupted")
        } catch {
            assertCode(error, "user_interrupted", 54)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertEqual(sleeper.waits.reduce(0, +), 2, accuracy: 0.0001)
        XCTAssertTrue(sleeper.waits.allSatisfy { $0 <= policy.userYieldCheckInterval })
        XCTAssertEqual(presence.calls.last, .setState(session: "default", state: .idle), "the paused cursor is restored")
        XCTAssertFalse(presence.calls.contains { if case .move = $0 { return true } else { return false } })
    }

    // MARK: Degraded and bypassed presence

    func testUnreachablePresenceStillDelivers() async throws {
        let presence = FakePresence()
        presence.available = false
        let fixture = makeFixture("presence-unavailable", presence: presence)

        let click = try await fixture.engine.click(clickRequest())
        let key = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp"))

        XCTAssertEqual(click.presence, .unavailable)
        XCTAssertEqual(key.presence, .unavailable)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
        XCTAssertEqual(fixture.keyboard.destinations.count, 1)
        XCTAssertEqual(presence.calls, [.acquire(session: "default", pid: 77), .acquire(session: "default", pid: 77)])
    }

    // MARK: Foreground (finding: --foreground bypassed abort, lease, and yield)

    func testForegroundLeasesAndChecksWithoutCursorOrGuard() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-foreground", presence: presence)

        let click = try await fixture.engine.click(clickRequest(foreground: true))
        let key = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true))

        // The click's target is the window under the point (pid 77). No glide,
        // no press, no loading cursor, and no guard: the real cursor moves and
        // the app is meant to come forward. The key ends any guard an earlier
        // background action left on the app before activating it.
        XCTAssertEqual(presence.calls, [
            .acquire(session: "default", pid: 77), .status, .acquire(session: "default", pid: 77), .probe, .status,
            .acquire(session: "default", pid: 77), .status, .acquire(session: "default", pid: 77), .probe, .guardEnd(pid: 77), .status,
        ])
        XCTAssertEqual(click.presence, .active)
        XCTAssertEqual(key.presence, .active)
        XCTAssertEqual(fixture.mouse.calls.first?.destination, .global)
    }

    func testForegroundStopsForTheAbortKey() async throws {
        let presence = FakePresence()
        presence.aborted = true
        let fixture = makeFixture("presence-foreground-abort", presence: presence)

        for action in [
            { _ = try await fixture.engine.click(self.clickRequest(foreground: true)) },
            { _ = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true)) },
            { _ = try await fixture.engine.key(KeyRequest(chord: "volumeup", foreground: true)) },
            { _ = try await fixture.engine.focus(FocusRequest(appIdentifier: "TargetApp")) },
        ] as [() async throws -> Void] {
            do {
                try await action()
                XCTFail("Expected aborted_by_user")
            } catch {
                assertCode(error, "aborted_by_user", 53)
            }
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
        XCTAssertFalse(presence.calls.contains(.guardEnd(pid: 77)), "focus stopped before ending the guard")
    }

    func testForegroundRespectsAnotherSessionsLease() async throws {
        let presence = FakePresence()
        presence.leaseHeld(by: "agent-b", pid: 77)
        let fixture = makeFixture("presence-foreground-busy", presence: presence)

        do {
            _ = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true))
            XCTFail("Expected target_busy")
        } catch {
            assertCode(error, "target_busy", 52)
        }
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
    }

    func testForegroundWaitsForAnyRecentUserInput() async throws {
        let presence = FakePresence()
        // Pointer motion over some other app: it shares the HID stream.
        presence.userInput(to: 999, kind: .ambient)
        var policy = PresencePolicy()
        policy.sleep = { presence.advance($0) }
        let fixture = makeFixture("presence-foreground-yield", presence: presence, policy: policy)

        let key = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true))

        XCTAssertEqual(key.presence, .active)
        XCTAssertEqual(presence.calls.filter { $0 == .status }.count, 3, "checked, waited, checked again, then the receipt")
        XCTAssertFalse(presence.calls.contains { if case .setState = $0 { return true } else { return false } }, "no paused cursor")
        XCTAssertEqual(fixture.keyboard.destinations.count, 1)
    }

    func testForegroundWithoutATargetChecksARunningPresenceOnly() async throws {
        let presence = FakePresence()
        presence.running = false
        let fixture = makeFixture("presence-foreground-system-key", presence: presence)

        let first = try await fixture.engine.key(KeyRequest(chord: "volumeup", foreground: true))
        XCTAssertEqual(first.presence, .unavailable, "nothing to ask: presence is not running")
        XCTAssertEqual(presence.calls, [.probe])

        presence.running = true
        let second = try await fixture.engine.key(KeyRequest(chord: "volumeup", foreground: true))
        XCTAssertEqual(second.presence, .active)
    }

    // MARK: Registration (finding: foreground CLI input counted as the user's)

    func testForegroundRegistersWithPresenceBeforePosting() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-foreground-registers", presence: presence)

        _ = try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true))

        XCTAssertEqual(presence.connectedAtDelivery, 0, "presence knew this process before its first event")
        // What the tap then sees: the engine's own events are not the user's.
        presence.userInput(to: 77, source: FakePresence.enginePID)
        XCTAssertNil(presence.snapshot.appInput[77])
        XCTAssertNil(presence.snapshot.lastUserInputAt)
    }

    func testForegroundSystemKeyRegistersWithARunningPresence() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-foreground-system-registers", presence: presence)
        _ = try await fixture.engine.key(KeyRequest(chord: "volumeup", foreground: true))
        XCTAssertEqual(presence.connectedAtDelivery, 0)
    }

    // MARK: Idle lifetimes (finding: serve never released anything)

    private func servePolicy() -> PresencePolicy {
        var policy = PresencePolicy.resolve(environment: [:], serve: true)
        policy.sleep = { _ in }
        return policy
    }

    func testServeLeaseIsReleasedOnceIdleWhileServeStaysConnected() async throws {
        let presence = FakePresence()
        let fixture = makeFixture(
            "presence-serve-idle",
            presence: presence,
            settings: PresenceSettings(defaultSession: "serve-1", cursorEnabled: true),
            policy: servePolicy()
        )

        _ = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(presence.lastAcquire?.holdMs, 0, "serve's leases end when it exits")
        XCTAssertEqual(presence.lastAcquire?.idleMs, 15_000)
        XCTAssertEqual(presence.lastAcquire?.lingerMs, 10_000)

        presence.advance(14)
        XCTAssertEqual(presence.snapshot.leases[77]?.session, "serve-1")
        presence.advance(1)
        XCTAssertNil(presence.snapshot.leases[77], "quiet for the idle period, still connected, lease gone")
        XCTAssertTrue(presence.snapshot.sessions.isEmpty, "no session left to keep the cursor or the Mac awake")

        presence.leaseHeld(by: "agent-b", pid: 77)
        XCTAssertEqual(presence.snapshot.leases[77]?.session, "agent-b")
    }

    func testServeLetsGoOfEverythingWhenItEnds() async throws {
        let presence = FakePresence()
        let fixture = makeFixture(
            "presence-serve-end",
            presence: presence,
            settings: PresenceSettings(defaultSession: "serve-1", cursorEnabled: true),
            policy: servePolicy()
        )
        _ = try await fixture.engine.click(clickRequest())
        XCTAssertNotNil(presence.snapshot.leases[77])

        fixture.engine.endPresence()

        XCTAssertTrue(presence.snapshot.leases.isEmpty)
        XCTAssertTrue(presence.snapshot.sessions.isEmpty)
    }

    func testOneShotLeaseOutlivesItsProcessUntilIdle() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-cli-idle", presence: presence, policy: PresencePolicy.resolve(environment: [:], serve: false))

        _ = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(presence.lastAcquire?.holdMs, 15_000)
        fixture.engine.endPresence()
        XCTAssertEqual(presence.snapshot.leases[77]?.session, "default", "the next CLI command finds its app still leased")

        presence.advance(15)
        XCTAssertNil(presence.snapshot.leases[77])
    }

    func testPolicyReadsIdleAndLingerFromTheEnvironment() {
        let policy = PresencePolicy.resolve(
            environment: ["SCREENCOMMANDER_LEASE_IDLE_MS": "4000", "SCREENCOMMANDER_CURSOR_LINGER_MS": "1500"],
            serve: false
        )
        XCTAssertEqual(policy.leaseIdleMs, 4_000)
        XCTAssertEqual(policy.cursorLingerMs, 1_500)
        XCTAssertEqual(policy.leaseHoldMs, 4_000)
        XCTAssertEqual(PresencePolicy.resolve(environment: ["SCREENCOMMANDER_LEASE_IDLE_MS": "1"], serve: true).leaseIdleMs, 500)
        XCTAssertEqual(PresencePolicy.resolve(environment: ["SCREENCOMMANDER_LEASE_IDLE_MS": "x"], serve: true).leaseIdleMs, 15_000)
    }

    // MARK: First action on an app (finding: yield never fired)

    func testFirstActionWaitsForTheUserTypingInTheTargetApp() async throws {
        let presence = FakePresence()
        // The user types in pid 77; no session has ever leased it.
        presence.userInput(to: 77)
        var policy = PresencePolicy()
        policy.sleep = { presence.advance($0) }
        let fixture = makeFixture("presence-first-action-yields", presence: presence, policy: policy)

        let result = try await fixture.engine.click(clickRequest())

        XCTAssertEqual(Array(presence.calls.prefix(4)), [
            .acquire(session: "default", pid: 77),
            .status,
            .setState(session: "default", state: .paused),
            .status,
        ])
        XCTAssertEqual(result.presence, .active)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testFirstActionFailsWhenTheUserKeepsTypingInTheTargetApp() async {
        let presence = FakePresence()
        presence.userInput(to: 77)
        var policy = PresencePolicy()
        policy.sleep = { seconds in
            presence.advance(seconds)
            presence.userInput(to: 77)
        }
        let fixture = makeFixture("presence-first-action-interrupted", presence: presence, policy: policy)

        do {
            _ = try await fixture.engine.click(clickRequest())
            XCTFail("Expected user_interrupted")
        } catch {
            assertCode(error, "user_interrupted", 54)
        }
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
    }

    func testTypingInAnotherAppDoesNotHoldUpABackgroundAction() async throws {
        let presence = FakePresence()
        presence.userInput(to: 12)
        let fixture = makeFixture("presence-other-app-input", presence: presence)
        _ = try await fixture.engine.click(clickRequest())
        XCTAssertFalse(presence.calls.contains(.setState(session: "default", state: .paused)))
    }

    // MARK: Guard receipts (finding: guardRestored matched any pid)

    func testGuardRestoredCountsOnlyTheTargetsGuard() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-guard-restored-pid", presence: presence)

        presence.guardRestores = [GuardRestoreStatus(pid: 88, restoreCount: 1, lastRestoreMsAgo: 0)]
        let other = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(other.focus?.guardRestored, false, "another app's guard restored, not this action's")
        XCTAssertNotEqual(other.focus?.preserved, false)

        presence.guardRestores = [GuardRestoreStatus(pid: 77, restoreCount: 1, lastRestoreMsAgo: 0)]
        let own = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(own.focus?.guardRestored, true)
        XCTAssertEqual(own.focus?.preserved, false)

        presence.guardRestores = [GuardRestoreStatus(pid: 77, restoreCount: 1, lastRestoreMsAgo: 60_000)]
        let stale = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(stale.focus?.guardRestored, false, "a restore from before the action does not count")
    }

    func testElementInAWindowThatIsNotOnScreenGetsNoCursorGlide() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-off-screen-element", presence: presence)
        fixture.windows.windows = [
            InputWindowTarget(pid: 77, windowID: 640, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), isOnScreen: false),
        ]
        fixture.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [
            AXElementRecord(id: "0.1", role: "AXButton", title: "Save", enabled: true, actions: ["AXPress"],
                            boundsPoints: RectD(x: 100, y: 200, w: 40, h: 20)),
        ])

        let result = try await fixture.engine.click(ClickRequest(
            x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false, primeClick: false, humanLike: false, modifiers: [],
            element: "Save", appIdentifier: "TargetApp"
        ))

        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertFalse(
            presence.calls.contains { if case .move = $0 { return true } else { return false } },
            "a cursor drawn at a hidden window's element would point at another app"
        )
    }

    func testFocusEndsTheGuardBeforeActivating() async throws {
        let presence = FakePresence()
        var callsAtActivation: [FakePresence.Call] = []
        let fixture = makeInputEngineFixture(
            "presence-focus-ends-guard",
            frontmostApp: { ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal") },
            activateApp: { _ in callsAtActivation = presence.calls },
            presence: presence
        )
        fixture.targets.apps["TargetApp"] = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")

        _ = try await fixture.engine.focus(FocusRequest(appIdentifier: "TargetApp"))

        XCTAssertEqual(callsAtActivation, [.probe, .guardEnd(pid: 77)], "a live guard would undo the activation the caller asked for")
    }

    func testDisabledControllerReportsDisabled() async throws {
        let fixture = makeInputEngineFixture("presence-disabled-controller")
        let result = try await fixture.engine.click(clickRequest())
        XCTAssertEqual(result.presence, .disabled)
        XCTAssertEqual(fixture.mouse.calls.count, 1)
    }

    func testCursorOffKeepsLeaseYieldAndGuard() async throws {
        let presence = FakePresence()
        let fixture = makeFixture(
            "presence-cursor-off",
            presence: presence,
            settings: PresenceSettings(defaultSession: "default", cursorEnabled: false)
        )

        let fromSettings = try await fixture.engine.click(clickRequest())
        let expected: [FakePresence.Call] = [
            .acquire(session: "default", pid: 77), .status, .guardBegin(pid: 77, delivered: 0), .acquire(session: "default", pid: 77), .probe, .guardRenew(pid: 77, delivered: 1), .status,
        ]
        XCTAssertEqual(presence.calls, expected)
        XCTAssertEqual(fromSettings.presence, .active)

        // A request can turn it back on, and the per-request switch also turns it off.
        _ = try await fixture.engine.click(clickRequest(agentCursor: true))
        XCTAssertTrue(presence.calls.contains { if case .move = $0 { return true } else { return false } })

        let onByDefault = FakePresence()
        let enabled = makeFixture("presence-cursor-off-request", presence: onByDefault)
        _ = try await enabled.engine.click(clickRequest(agentCursor: false))
        XCTAssertEqual(onByDefault.calls, expected)
    }

    func testRequestSessionOverridesTheProcessDefault() async throws {
        let presence = FakePresence()
        let fixture = makeFixture(
            "presence-session-override",
            presence: presence,
            settings: PresenceSettings(defaultSession: "serve-123", cursorEnabled: true)
        )

        _ = try await fixture.engine.click(clickRequest())
        _ = try? await fixture.engine.click(clickRequest(session: "agent-a"))

        let sessions = presence.calls.compactMap { call -> String? in
            if case .acquire(let session, _) = call { return session }
            return nil
        }
        // agent-a is refused: serve-123 still holds pid 77.
        XCTAssertEqual(sessions, ["serve-123", "serve-123", "agent-a"])
    }

    func testPresenceSettingsResolveSessionAndCursorFromEnvironment() {
        XCTAssertEqual(PresenceSettings.resolve(environment: [:]), PresenceSettings(defaultSession: "default", cursorEnabled: true))
        XCTAssertEqual(PresenceSettings.resolve(environment: [:], serveProcessID: 4321).defaultSession, "serve-4321")
        XCTAssertEqual(
            PresenceSettings.resolve(environment: ["SCREENCOMMANDER_SESSION": "agent-7"], serveProcessID: 4321).defaultSession,
            "agent-7",
            "the environment beats serve's per-process ID"
        )
        XCTAssertEqual(PresenceSettings.resolve(environment: ["SCREENCOMMANDER_SESSION": "  "]).defaultSession, "default")
        XCTAssertFalse(PresenceSettings.resolve(environment: ["SCREENCOMMANDER_AGENT_CURSOR": "0"]).cursorEnabled)
        XCTAssertTrue(PresenceSettings.resolve(environment: ["SCREENCOMMANDER_AGENT_CURSOR": "1"]).cursorEnabled)
        XCTAssertFalse(PresenceSettings.presenceEnabled(environment: ["SCREENCOMMANDER_PRESENCE": "0"]))
        XCTAssertTrue(PresenceSettings.presenceEnabled(environment: [:]))
    }

    // MARK: Serialization

    func testConcurrentActionsOnOnePidDoNotInterleave() async throws {
        let presence = FakePresence()
        let gate = WindowResolutionGate()
        presence.moveGate = gate
        let fixture = makeFixture("presence-serialized", presence: presence, focusSampler: LockedFocusSampler())
        let engine = fixture.engine
        let request = clickRequest()

        let first = Task { try await engine.click(request) }
        try await waitUntil { presence.calls.contains { if case .move = $0 { return true } else { return false } } }

        let second = Task { try await engine.click(request) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            presence.calls.filter { if case .acquire = $0 { return true } else { return false } }.count,
            1,
            "the second action waits for the first to finish delivering"
        )
        XCTAssertTrue(fixture.mouse.calls.isEmpty)

        await gate.open()
        _ = try await first.value
        _ = try await second.value

        // The receipt's focus-guard check runs after the serializer lets the next
        // action in, so status calls are counted rather than placed.
        XCTAssertEqual(presence.calls.filter { $0 != .status }, [
            .acquire(session: "default", pid: 77),
            .move(session: "default", point: Self.clickPoint, windowID: 500),
            .guardBegin(pid: 77, delivered: 0), .acquire(session: "default", pid: 77), .probe, .press(session: "default", count: 1, delivered: 1),
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 1),
            .acquire(session: "default", pid: 77), .setState(session: "default", state: .idle),
            .move(session: "default", point: Self.clickPoint, windowID: 500),
            .guardBegin(pid: 77, delivered: 1), .acquire(session: "default", pid: 77), .probe, .press(session: "default", count: 1, delivered: 2),
            .setState(session: "default", state: .loading), .guardRenew(pid: 77, delivered: 2),
        ])
        XCTAssertEqual(presence.calls.filter { $0 == .status }.count, 4)
    }

    func testForegroundActionsOnDifferentAppsDoNotInterleave() async throws {
        let presence = FakePresence()
        let gate = WindowResolutionGate()
        presence.acquireGate = gate
        let fixture = makeFixture("presence-serialized-foreground", presence: presence, focusSampler: LockedFocusSampler())
        fixture.targets.apps["OtherApp"] = ResolvedApp(pid: 88, name: "OtherApp", bundleID: "com.example.other")
        let engine = fixture.engine

        let first = Task { try await engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp", foreground: true)) }
        try await waitUntil { presence.calls.contains(.acquire(session: "default", pid: 77)) }
        let second = Task { try await engine.key(KeyRequest(chord: "b", appIdentifier: "OtherApp", foreground: true)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(presence.calls.contains(.acquire(session: "default", pid: 88)), "both post through the HID tap")
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)

        await gate.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(fixture.keyboard.destinations.count, 2)
    }

    func testForegroundCoordinateActionWaitsForBackgroundDeliveryToTheSameApp() async throws {
        let presence = FakePresence()
        let gate = WindowResolutionGate()
        presence.acquireGate = gate
        let fixture = makeFixture("presence-serialized-mixed", presence: presence, focusSampler: LockedFocusSampler())
        let engine = fixture.engine

        let background = Task { try await engine.click(self.clickRequest()) }
        try await waitUntil { presence.calls.count == 1 }
        let foreground = Task {
            try await engine.click(ClickRequest(
                x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil,
                button: .left, doubleClick: false, triple: false,
                primeClick: false, humanLike: true, modifiers: [],
                appIdentifier: "TargetApp", foreground: true
            ))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presence.calls.count, 1, "the foreground click waits for the background one")
        XCTAssertTrue(fixture.mouse.calls.isEmpty)

        await gate.open()
        _ = try await background.value
        _ = try await foreground.value
        XCTAssertEqual(fixture.mouse.calls.map(\.destination), [.window(fixtureWindow), .global])
    }

    func testSerializerKeysPutTheSharedGlobalKeyFirst() {
        XCTAssertEqual(InputSerializer.keys(pid: 77, global: false), [77])
        XCTAssertEqual(InputSerializer.keys(pid: 77, global: true), [InputSerializer.globalKey, 77])
        XCTAssertEqual(InputSerializer.keys(pid: nil, global: true), [InputSerializer.globalKey])
        XCTAssertEqual(InputSerializer.keys(pid: nil, global: false), [InputSerializer.globalKey])
    }

    func testSerializerBlocksOnlyTheSamePid() async throws {
        let serializer = InputSerializer()
        await serializer.acquire(77)
        await serializer.acquire(88)

        let order = OrderLog()
        let waiter = Task {
            await serializer.acquire(77)
            order.append("second-77")
            await serializer.release(77)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        order.append("first-77-done")
        await serializer.release(77)
        await waiter.value
        await serializer.release(88)

        XCTAssertEqual(order.entries, ["first-77-done", "second-77"])
    }

    // MARK: Real presence socket

    func testRealPresenceServerEnforcesLeasesAndAbort() async throws {
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scp-\(UUID().uuidString.prefix(8)).sock").path
        let core = PresenceCore(driver: HeadlessCursorDriver())
        let server = PresenceSocketServer(socketPath: socketPath, core: core)
        try server.start()
        defer { server.stop() }

        func engine(_ name: String, session: String) -> InputEngineFixture {
            let client = PresenceClient(configuration: PresenceClientConfiguration(socketPath: socketPath, clientName: name))
            let fixture = makeInputEngineFixture(
                name,
                presence: LivePresenceController(client: client),
                presenceSettings: PresenceSettings(defaultSession: session, cursorEnabled: true)
            )
            return fixture
        }
        let agentA = engine("presence-real-a", session: "agent-a")
        let agentB = engine("presence-real-b", session: "agent-b")

        let first = try await agentA.engine.click(clickRequest())
        XCTAssertEqual(first.presence, .active)
        XCTAssertEqual(core.snapshot.leases[77]?.session, "agent-a")

        do {
            _ = try await agentB.engine.click(clickRequest())
            XCTFail("Expected target_busy")
        } catch {
            assertCode(error, "target_busy", 52)
        }
        XCTAssertTrue(agentB.mouse.calls.isEmpty)

        core.recordUserInput(sourcePID: 0, targetPID: nil, isAbortChord: true)
        do {
            _ = try await agentA.engine.click(clickRequest())
            XCTFail("Expected aborted_by_user")
        } catch {
            assertCode(error, "aborted_by_user", 53)
        }
        XCTAssertEqual(agentA.mouse.calls.count, 1)

        let resumer = PresenceClient(configuration: PresenceClientConfiguration(socketPath: socketPath))
        let resumed = await resumer.resume()
        XCTAssertNotNil(resumed.value)
        let afterResume = try await agentA.engine.click(clickRequest())
        XCTAssertEqual(afterResume.presence, .active)
        XCTAssertEqual(agentA.mouse.calls.count, 2)
    }

    // MARK: Capture exclusion

    func testOverlayExclusionPicksPresenceWindowsOnly() {
        let candidates = [
            OverlayWindowCandidate(windowID: 10, ownerPID: 500, title: "Document"),
            OverlayWindowCandidate(windowID: 11, ownerPID: 999, title: nil),
            OverlayWindowCandidate(windowID: 12, ownerPID: 600, title: nil),
            OverlayWindowCandidate(windowID: 13, ownerPID: 700, title: OverlayExclusion.cursorWindowTitle),
            OverlayWindowCandidate(windowID: 14, ownerPID: 800, title: "ScreenCommander Input Fixture"),
        ]

        XCTAssertEqual(
            OverlayExclusion.select(onScreen: candidates, presenceServerPID: 999, reportedWindowIDs: [12, 77]),
            [11, 12, 13],
            "owned by presence, reported by presence, or titled as the cursor; 77 is not on screen"
        )
        XCTAssertEqual(
            OverlayExclusion.select(onScreen: candidates, presenceServerPID: nil, reportedWindowIDs: []),
            [13],
            "without presence, the cursor title still identifies the window"
        )
        XCTAssertEqual(OverlayExclusion.select(onScreen: candidates, presenceServerPID: 0, reportedWindowIDs: []), [13])
    }

    func testWarmContentMissingAnOverlayNeedsRefresh() {
        XCTAssertFalse(OverlayExclusion.needsRefresh(overlayWindowIDs: [], contentWindowIDs: [1, 2]))
        XCTAssertFalse(OverlayExclusion.needsRefresh(overlayWindowIDs: [2], contentWindowIDs: [1, 2]))
        XCTAssertTrue(OverlayExclusion.needsRefresh(overlayWindowIDs: [2, 3], contentWindowIDs: [1, 2]))
    }

    // MARK: Plumbing

    func testMCPActionToolsAcceptSessionAndAgentCursor() throws {
        let fixture = makeInputEngineFixture("presence-mcp-schema")
        let registry = MCPToolRegistry(engine: fixture.engine, doctor: DoctorService(presence: {
            DoctorPresenceStatus(socketPath: "/tmp/x.sock", reply: .unavailable("test"))
        }))
        for name in ["click", "type", "key", "keys", "scroll", "drag", "move"] {
            let properties = registry.tools.first { $0.name == name }?.inputSchema["properties"]
            XCTAssertNotNil(properties?["session"], name)
            XCTAssertNotNil(properties?["agentCursor"], name)
        }
        XCTAssertNil(registry.tools.first { $0.name == "screenshot" }?.inputSchema["properties"]?["session"])
    }

    func testMCPClickPassesSessionAndCursorToTheEngine() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("presence-mcp-call", presence: presence)
        let registry = MCPToolRegistry(engine: fixture.engine, doctor: DoctorService(presence: {
            DoctorPresenceStatus(socketPath: "/tmp/x.sock", reply: .unavailable("test"))
        }))

        let outcome = await registry.call(name: "click", arguments: .object([
            "x": .number(200), "y": .number(100), "session": .string("mcp-agent"), "agentCursor": .bool(false),
        ]))

        XCTAssertEqual(outcome?.isError, false)
        XCTAssertEqual(outcome?.envelope["result"]?["action"]?["presence"]?.stringValue, "active")
        XCTAssertEqual(presence.calls, [.acquire(session: "mcp-agent", pid: 77), .status, .guardBegin(pid: 77, delivered: 0), .acquire(session: "mcp-agent", pid: 77), .probe, .guardRenew(pid: 77, delivered: 1), .status])
    }

    func testSequenceStepsDecodeSessionAndAgentCursor() throws {
        let json = """
        {"steps": [
            {"click": {"x": 1, "y": 2, "session": "seq", "agentCursor": false}},
            {"key": {"chord": "a", "session": "seq"}}
        ]}
        """
        let file = try JSONDecoder().decode(SequenceFile.self, from: Data(json.utf8))
        guard case .click(let click) = file.steps[0], case .key(let key) = file.steps[1] else {
            return XCTFail("Unexpected steps")
        }
        XCTAssertEqual(click.session, "seq")
        XCTAssertEqual(click.agentCursor, false)
        XCTAssertEqual(key.session, "seq")
        XCTAssertNil(key.agentCursor)
    }

    func testCLIParsesSessionAndNoAgentCursor() throws {
        let click = try ClickCommand.parse(["10", "20", "--session", "agent-a", "--no-agent-cursor"])
        XCTAssertEqual(click.presence.session, "agent-a")
        XCTAssertEqual(click.presence.agentCursor, false)
        let key = try KeyCommand.parse(["a"])
        XCTAssertNil(key.presence.session)
        XCTAssertNil(key.presence.agentCursor)
    }

    /// `parse` runs ArgumentParser's debug-build validation, which rejects a Bool
    /// flag that defaults to true without an inversion.
    func testInputCommandsParsePostshotAndNoPostshot() throws {
        XCTAssertTrue(try KeysCommand.parse(["press:a"]).postshot)
        XCTAssertFalse(try KeysCommand.parse(["press:a", "--no-postshot"]).postshot)
        XCTAssertFalse(try KeyCommand.parse(["a", "--no-postshot"]).postshot)
        XCTAssertFalse(try TypeCommand.parse(["hi", "--no-postshot"]).postshot)
        XCTAssertFalse(try ClickCommand.parse(["10", "20", "--no-postshot"]).postshot)
        XCTAssertFalse(try ScrollCommand.parse(["100", "200", "--dx", "10", "--no-postshot"]).postshot)
        XCTAssertFalse(try MoveCommand.parse(["10", "20", "--no-postshot"]).postshot)
        XCTAssertFalse(try DragCommand.parse(["1", "2", "3", "4", "--no-postshot"]).postshot)
        XCTAssertFalse(try SequenceCommand.parse(["--file", "steps.json", "--no-postshot"]).postshot)
    }

    func testResultsEncodePresence() throws {
        let result = KeyResult(normalizedChord: "a", presence: .unavailable)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(object?["presence"] as? String, "unavailable")
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("Condition not met within \(timeout) s")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

// MARK: - Parity tools (state, apps, launch, select-text, action, page scroll) and profiles

final class ParityToolsEngineTests: XCTestCase {
    private static let app = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
    private static let windowInfo = WindowInfo(
        windowID: 500, title: "Doc", appName: "TargetApp", pid: 77,
        boundsPoints: RectD(x: 100, y: 200, w: 400, h: 300), isOnScreen: true, layer: 0
    )

    private func record(
        _ id: String,
        role: String = "AXButton",
        title: String? = nil,
        value: String? = nil,
        actions: [String] = [],
        bounds: RectD? = RectD(x: 110, y: 210, w: 40, h: 20)
    ) -> AXElementRecord {
        AXElementRecord(id: id, role: role, title: title, value: value, actions: actions, boundsPoints: bounds)
    }

    private func makeFixture(
        _ name: String,
        records: [AXElementRecord] = [],
        windows: [InputWindowTarget] = [fixtureWindow],
        focusSamples: [FocusSample]? = nil,
        profile: @escaping (pid_t) -> BackgroundDeliveryProfile = { _ in .native },
        bundleProfile: @escaping (URL?) -> BackgroundDeliveryProfile = { _ in .native },
        catalog: FakeAppCatalog = FakeAppCatalog(),
        launcher: FakeAppLauncher = FakeAppLauncher(),
        presence: PresenceControlling = DisabledPresenceController()
    ) -> InputEngineFixture {
        let fixture = makeInputEngineFixture(
            name,
            frontmostApp: { ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal") },
            windows: windows,
            focusSamples: focusSamples,
            profile: profile,
            bundleProfile: bundleProfile,
            appCatalog: catalog,
            appLauncher: launcher,
            presence: presence
        )
        fixture.targets.apps["TargetApp"] = Self.app
        fixture.targets.windowByIdentifier["500"] = Self.windowInfo
        fixture.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: records)
        return fixture
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (ScreenCommanderError) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, code, "\(error)", file: file, line: line)
            check(error)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: state

    func testStateCapturesTheFrontWindowAndReadsItsTreeWithElementsIDs() async throws {
        let records = [record("0", role: "AXWindow", title: "Doc", bounds: nil), record("0.1", title: "Save", actions: ["AXPress"])]
        let fixture = makeFixture("parity-state", records: records)

        let result = try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp"))

        XCTAssertEqual(result.windowID, 500)
        XCTAssertEqual(result.screenshot.windowID, 500)
        XCTAssertEqual(fixture.targets.resolveWindowCalls, ["500"])
        XCTAssertEqual(fixture.reader.treeCalls.last?.options.windowID, 500)
        XCTAssertEqual(result.tree.elements.map(\.id), ["0", "0.1"])
        XCTAssertEqual(result.tree.windowID, 500)
        // Pixel bounds map against this capture, not whatever last-screenshot.json held.
        XCTAssertEqual(result.tree.metadataPath, result.metadataPath)
        // The one-shot CLI returns the full tree with no snapshot bookkeeping.
        XCTAssertNil(result.tree.snapshotId)
        XCTAssertNil(result.tree.baseSnapshotId)

        let elements = try await fixture.engine.elements(ElementsRequest(appIdentifier: "TargetApp", windowID: 500))
        XCTAssertEqual(elements.elements.map(\.id), result.tree.elements.map(\.id))
    }

    func testStateInServeModeReturnsADeltaAfterTheFirstCall() async throws {
        let fixture = makeFixture("parity-state-diff", records: [
            record("0", role: "AXWindow", bounds: nil),
            record("0.1", title: "Save"),
            record("0.2", title: "Cancel"),
        ])
        var request = AppStateRequest(appIdentifier: "TargetApp")
        request.diff = true

        let first = try await fixture.engine.appState(request)
        let baseline = try XCTUnwrap(first.tree.snapshotId)
        XCTAssertNil(first.tree.baseSnapshotId)
        XCTAssertEqual(first.tree.elements.count, 3)

        fixture.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [
            record("0", role: "AXWindow", bounds: nil),
            record("0.1", title: "Saved"),
        ])
        let second = try await fixture.engine.appState(request)
        XCTAssertEqual(second.tree.baseSnapshotId, baseline)
        XCTAssertEqual(second.tree.elements.map(\.id), ["0.1"])
        XCTAssertEqual(second.tree.removedIds, ["0.2"])

        request.fullTree = true
        let full = try await fixture.engine.appState(request)
        XCTAssertNil(full.tree.baseSnapshotId)
        XCTAssertEqual(full.tree.elements.count, 2)
        XCTAssertNotNil(full.tree.snapshotId)
    }

    func testStateUsesTheMinimizedWindowPathWhenNothingIsOnScreen() async throws {
        let fixture = makeFixture("parity-state-minimized", records: [record("0", role: "AXWindow", bounds: nil)], windows: [])
        fixture.windows.minimized[77] = [500]

        let front = try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp"))
        XCTAssertEqual(front.windowID, 500)

        var explicit = AppStateRequest(appIdentifier: "TargetApp")
        explicit.windowID = 500
        let byID = try await fixture.engine.appState(explicit)
        XCTAssertEqual(byID.windowID, 500)
        XCTAssertEqual(fixture.targets.resolveWindowCalls, ["500", "500"], "both go through the window capture path")

        explicit.windowID = 501
        await assertThrows(try await fixture.engine.appState(explicit), code: "window_not_found")
    }

    func testStateFallsBackToAHiddenAppsWindow() async throws {
        let hidden = InputWindowTarget(pid: 77, windowID: 640, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), isOnScreen: false)
        let fixture = makeFixture("parity-state-hidden", records: [record("0", role: "AXWindow", bounds: nil)], windows: [hidden])
        fixture.targets.windowByIdentifier["640"] = Self.windowInfo

        let result = try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp"))
        XCTAssertEqual(result.windowID, 640, "a hidden app's window is captured through the window server")

        let byID = try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp", windowID: 640))
        XCTAssertEqual(byID.windowID, 640)
    }

    func testStateWithoutAWindowFailsWithWindowNotFound() async {
        let fixture = makeFixture("parity-state-no-window", windows: [])
        await assertThrows(try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp")), code: "window_not_found")
    }

    func testStateRejectsAWindowOfAnotherApp() async {
        let other = InputWindowTarget(pid: 88, windowID: 900, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let fixture = makeFixture("parity-state-other-window", windows: [fixtureWindow, other])
        await assertThrows(
            try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp", windowID: 900)),
            code: "invalid_arguments"
        )
    }

    // MARK: apps

    func testAppsListsRunningAndInstalledWithFilter() {
        let catalog = FakeAppCatalog()
        catalog.running = [
            RunningAppEntry(name: "Finder", bundleID: "com.apple.finder", pid: 10, frontmost: false, windowCount: 2, activationPolicy: "regular"),
            RunningAppEntry(name: "Terminal", bundleID: "com.apple.Terminal", pid: 12, frontmost: true, windowCount: 1, activationPolicy: "regular"),
        ]
        catalog.installed = [
            InstalledAppEntry(name: "Calculator", bundleID: "com.apple.calculator", path: "/System/Applications/Calculator.app", running: false),
            InstalledAppEntry(name: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", running: true),
        ]
        let fixture = makeFixture("parity-apps", catalog: catalog)

        let all = fixture.engine.apps(AppsRequest())
        XCTAssertEqual(all.running.count, 2)
        XCTAssertEqual(all.installed?.count, 2)
        XCTAssertNil(all.installedTruncated)

        let filtered = fixture.engine.apps(AppsRequest(filter: "TERM"))
        XCTAssertEqual(filtered.running.map(\.name), ["Terminal"])
        XCTAssertEqual(filtered.installed?.map(\.name), ["Terminal"])

        let runningOnly = fixture.engine.apps(AppsRequest(includeInstalled: false))
        XCTAssertNil(runningOnly.installed)
        XCTAssertEqual(catalog.installedScans, 2)
    }

    // MARK: launch

    private func calculatorCatalog() -> FakeAppCatalog {
        let catalog = FakeAppCatalog()
        catalog.installed = [
            InstalledAppEntry(name: "Calculator", bundleID: "com.apple.calculator", path: "/System/Applications/Calculator.app", running: false),
        ]
        return catalog
    }

    func testLaunchStopsForTheAbortKey() async throws {
        let presence = FakePresence()
        presence.aborted = true
        let launcher = FakeAppLauncher()
        let fixture = makeFixture("parity-launch-aborted", catalog: calculatorCatalog(), launcher: launcher, presence: presence)

        await assertThrows(try await fixture.engine.launch(LaunchRequest(appIdentifier: "calc")), code: "aborted_by_user")
        XCTAssertTrue(launcher.launched.isEmpty)
    }

    func testLaunchStartsInTheBackgroundUnderTheFocusGuard() async throws {
        let presence = FakePresence()
        let launcher = FakeAppLauncher()
        let fixture = makeFixture("parity-launch", catalog: calculatorCatalog(), launcher: launcher, presence: presence)

        let result = try await fixture.engine.launch(LaunchRequest(appIdentifier: "calc"))

        XCTAssertEqual(launcher.launched, [URL(fileURLWithPath: "/System/Applications/Calculator.app")])
        XCTAssertEqual(launcher.waited.first?.pid, 4_242)
        XCTAssertEqual(launcher.waited.first?.timeout, 10)
        XCTAssertEqual(result.app, ResolvedApp(pid: 4_242, name: "Calculator", bundleID: "com.apple.calculator"))
        XCTAssertFalse(result.alreadyRunning)
        XCTAssertTrue(result.ready)
        XCTAssertTrue(result.focus.preserved)
        XCTAssertEqual(result.presence, .active)
        // Presence is started before the launch, and the guard covers the new pid.
        XCTAssertEqual(presence.calls.first, .status)
        XCTAssertEqual(presence.calls.filter { $0 == .guardBegin(pid: 4_242, delivered: 0) }.count, 1)
    }

    func testLaunchPassesTheAppSampledBeforeLaunchToItsGuard() async throws {
        let presence = FakePresence()
        let launcher = FakeAppLauncher()
        var earlyActivation = false
        launcher.onLaunch = { earlyActivation = true }
        let fixture = makeFixture("parity-launch-early-activation", catalog: calculatorCatalog(), launcher: launcher, presence: presence)
        _ = try await fixture.engine.launch(LaunchRequest(appIdentifier: "Calculator"))
        XCTAssertTrue(earlyActivation)
        XCTAssertEqual(presence.launchPreviousPID, 12)
        XCTAssertEqual(presence.calls.filter { $0 == .guardBegin(pid: 4_242, delivered: 0) }.count, 1)
        XCTAssertEqual(presence.calls.filter { $0 == .guardRenew(pid: 4_242, delivered: 0) }.count, 1)
    }

    func testLaunchReportsAFocusChange() async throws {
        let terminal = FocusSample(frontmostPid: 12, frontmostBundleID: "com.apple.Terminal", cursor: CGPoint(x: 5, y: 5))
        let calculator = FocusSample(frontmostPid: 4_242, frontmostBundleID: "com.apple.calculator", cursor: CGPoint(x: 5, y: 5))
        let fixture = makeFixture("parity-launch-steal", focusSamples: [terminal, calculator], catalog: calculatorCatalog())

        let result = try await fixture.engine.launch(LaunchRequest(appIdentifier: "Calculator"))

        XCTAssertFalse(result.focus.preserved)
        XCTAssertEqual(result.focus.frontmostAfter, "com.apple.calculator")
        XCTAssertEqual(result.presence, .disabled)
    }

    func testLaunchOfARunningAppDoesNotRelaunch() async throws {
        let catalog = calculatorCatalog()
        catalog.running = [
            RunningAppEntry(name: "Calculator", bundleID: "com.apple.calculator", pid: 321, frontmost: false, windowCount: 1, activationPolicy: "regular"),
        ]
        let launcher = FakeAppLauncher()
        let fixture = makeFixture("parity-launch-running", catalog: catalog, launcher: launcher)

        let result = try await fixture.engine.launch(LaunchRequest(appIdentifier: "com.apple.calculator"))

        XCTAssertTrue(result.alreadyRunning)
        XCTAssertEqual(result.app.pid, 321)
        XCTAssertTrue(launcher.launched.isEmpty)
    }

    func testLaunchOfAnUnknownAppFailsWithAppNotFound() async {
        let fixture = makeFixture("parity-launch-unknown", catalog: calculatorCatalog())
        await assertThrows(try await fixture.engine.launch(LaunchRequest(appIdentifier: "Nope")), code: "app_not_found")
        await assertThrows(
            try await fixture.engine.launch(LaunchRequest(appIdentifier: "Calculator", timeoutMS: 0)),
            code: "invalid_arguments"
        )
    }

    // MARK: select-text

    func testSelectTextBySubstringUsesUTF16RangeAndVerifies() async throws {
        let fixture = makeFixture("parity-select", records: [record("0.2", role: "AXTextField", title: "Name")])
        fixture.axActions.readValueResult = "👋 Hello world"
        fixture.axActions.selectedTextResult = "world"

        let result = try await fixture.engine.selectText(SelectTextRequest(element: "Name", appIdentifier: "TargetApp", text: "WORLD"))

        // The emoji is two UTF-16 units, so "world" starts at 9, not 8.
        XCTAssertEqual(result.range, AXTextRange(location: 9, length: 5))
        XCTAssertEqual(fixture.axActions.selectionWrites, [AXTextRange(location: 9, length: 5)])
        XCTAssertEqual(result.selectedRange, AXTextRange(location: 9, length: 5))
        XCTAssertEqual(result.selectedText, "world")
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertTrue(fixture.mouse.allDestinations.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
    }

    func testSelectTextFocusesTheElementWhenTheFirstWriteFails() async throws {
        let fixture = makeFixture("parity-select-focus", records: [record("0.2", role: "AXTextArea", title: "Notes")])
        fixture.axActions.readValueResult = "abcdef"
        fixture.axActions.selectionNeedsFocus = true

        let result = try await fixture.engine.selectText(
            SelectTextRequest(element: "Notes", appIdentifier: "TargetApp", range: AXTextRange(location: 1, length: 3))
        )

        XCTAssertEqual(fixture.axActions.focusCount, 1)
        XCTAssertEqual(result.verified, .checked(true))
    }

    func testSelectTextValidatesItsArguments() async {
        let fixture = makeFixture("parity-select-invalid", records: [record("0.2", role: "AXTextField", title: "Name")])
        fixture.axActions.readValueResult = "abc"

        await assertThrows(try await fixture.engine.selectText(SelectTextRequest(element: "Name", appIdentifier: "TargetApp")), code: "invalid_arguments")
        await assertThrows(
            try await fixture.engine.selectText(SelectTextRequest(element: "Name", appIdentifier: "TargetApp", range: AXTextRange(location: 2, length: 5))),
            code: "invalid_arguments"
        )
        await assertThrows(
            try await fixture.engine.selectText(SelectTextRequest(element: "Name", appIdentifier: "TargetApp", text: "zzz")),
            code: "invalid_arguments"
        ) { error in
            XCTAssertTrue(error.description.contains("zzz"))
        }
        XCTAssertTrue(fixture.axActions.selectionWrites.isEmpty)
    }

    // MARK: action

    func testPerformActionRunsAListedAction() async throws {
        let fixture = makeFixture("parity-action", records: [record("0.3", title: "Volume", actions: ["AXIncrement", "AXDecrement", "AXShowMenu"])])

        let result = try await fixture.engine.performAction(PerformActionRequest(element: "Volume", appIdentifier: "TargetApp", name: "showmenu"))

        XCTAssertEqual(result.name, "AXShowMenu")
        XCTAssertEqual(fixture.axActions.performedActions, ["AXShowMenu"])
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.element.id, "0.3")
        XCTAssertTrue(fixture.mouse.allDestinations.isEmpty)
    }

    func testPerformActionRejectsUnlistedNamesWithTheAvailableOnes() async {
        let fixture = makeFixture("parity-action-unlisted", records: [record("0.3", title: "Volume", actions: ["AXIncrement", "AXDecrement"])])

        await assertThrows(
            try await fixture.engine.performAction(PerformActionRequest(element: "Volume", appIdentifier: "TargetApp", name: "AXPress")),
            code: "element_not_actionable"
        ) { error in
            XCTAssertTrue(error.description.contains("AXIncrement, AXDecrement"), error.description)
        }
        XCTAssertTrue(fixture.axActions.performedActions.isEmpty)
    }

    func testPerformActionGoesThroughPresence() async throws {
        let presence = FakePresence()
        let fixture = makeFixture("parity-action-presence", records: [record("0.3", title: "Go", actions: ["AXPress"])], presence: presence)

        let result = try await fixture.engine.performAction(PerformActionRequest(element: "Go", appIdentifier: "TargetApp", name: "AXPress"))

        XCTAssertEqual(result.presence, .active)
        XCTAssertEqual(presence.calls.first, .acquire(session: "default", pid: 77))
        XCTAssertTrue(presence.calls.contains(.move(session: "default", point: PresencePoint(x: 130, y: 220), windowID: 500)))
        XCTAssertTrue(presence.calls.contains { if case .press(_, 1, _) = $0 { return true } else { return false } })
    }

    // MARK: page scroll

    private func pageScroll(
        _ direction: ScrollDirection,
        pages: Int = 1,
        via: InputDeliveryMethod? = nil,
        element: String? = "Content"
    ) -> ScrollRequest {
        ScrollRequest(
            x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: 0, unit: .lines,
            element: element, appIdentifier: "TargetApp", via: via, direction: direction, pages: pages
        )
    }

    func testPageScrollPrefersAX() async throws {
        let fixture = makeFixture("parity-page-ax", records: [record("0.5", role: "AXScrollArea", title: "Content", bounds: RectD(x: 100, y: 200, w: 300, h: 200))])

        let result = try await fixture.engine.scroll(pageScroll(.down, pages: 2))

        XCTAssertEqual(fixture.axActions.pageScrolls.map(\.pages), [2])
        XCTAssertEqual(fixture.axActions.pageScrolls.first?.direction, .down)
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.axMethod, "AXScrollDownByPage")
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(result.direction, .down)
        XCTAssertEqual(result.pages, 2)
        XCTAssertTrue(fixture.mouse.scrollCalls.isEmpty)
    }

    func testPartiallyCompletedAXPagesDoNotReplayThroughWheel() async {
        let fixture = makeFixture("parity-page-partial", records: [record("0.5", role: "AXScrollArea", title: "Content")])
        fixture.axActions.scrollError = AXPartialScrollError(
            completedPages: 1, underlyingError: ScreenCommanderError.elementNotActionable("second AX page failed")
        )
        await assertThrows(try await fixture.engine.scroll(pageScroll(.down, pages: 3)), code: "element_not_actionable")
        XCTAssertTrue(fixture.mouse.scrollCalls.isEmpty)
    }

    func testPageScrollFallsBackToWheelEventsAtTheElementCenter() async throws {
        let fixture = makeFixture("parity-page-wheel", records: [record("0.5", role: "AXScrollArea", title: "Content", bounds: RectD(x: 100, y: 200, w: 300, h: 200))])
        fixture.axActions.scrollError = ScreenCommanderError.elementNotActionable("no AX scroll")
        fixture.axActions.scrollPositions = [0.1, 0.6]

        let result = try await fixture.engine.scroll(pageScroll(.down, pages: 2))

        XCTAssertEqual(fixture.mouse.scrollCalls.count, 2)
        let call = try XCTUnwrap(fixture.mouse.scrollCalls.first)
        XCTAssertEqual(call.point, CGPoint(x: 250, y: 300))
        XCTAssertEqual(call.dy, -180)
        XCTAssertEqual(call.dx, 0)
        XCTAssertEqual(call.unit, .pixels)
        XCTAssertEqual(call.destination, .window(fixtureWindow))
        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(result.dy, -360)
        XCTAssertEqual(result.verified, .checked(true))
    }

    func testPageScrollStepsAndArguments() async {
        XCTAssertEqual(ScreenCommanderEngine.pageStep(direction: .up, bounds: RectD(x: 0, y: 0, w: 100, h: 100)).dy, 90)
        let right = ScreenCommanderEngine.pageStep(direction: .right, bounds: RectD(x: 0, y: 0, w: 200, h: 100))
        XCTAssertEqual(right.dx, -180)
        XCTAssertEqual(right.dy, 0)
        XCTAssertEqual(ScreenCommanderEngine.pageStep(direction: .down, bounds: nil).unit, .lines)

        let fixture = makeFixture("parity-page-invalid", records: [record("0.5", role: "AXScrollArea", title: "Content")])
        await assertThrows(try await fixture.engine.scroll(pageScroll(.down, element: nil)), code: "invalid_arguments")
        await assertThrows(try await fixture.engine.scroll(pageScroll(.down, pages: 0)), code: "invalid_arguments")
        var mixed = pageScroll(.down)
        mixed.dy = 3
        await assertThrows(try await fixture.engine.scroll(mixed), code: "invalid_arguments")
    }

    // MARK: delivery profiles in the ladder

    private static let unsupportedProfile = BackgroundDeliveryPolicy.profile(
        for: AppBundleClassification(toolkit: .gameEngine, engine: "unity", evidence: ["Contents/Frameworks/UnityPlayer.dylib"]),
        capabilities: .all,
        authenticatedKeyboardOS: true
    )

    private func coordinateClick(via: InputDeliveryMethod? = nil, foreground: Bool = false) -> ClickRequest {
        ClickRequest(
            x: 200, y: 100, coordinateSpace: .pixels, metadataPath: nil, button: .left,
            doubleClick: false, triple: false, primeClick: false, humanLike: false, modifiers: [],
            via: via, foreground: foreground
        )
    }

    func testUnsupportedProfileRefusesBackgroundCoordinateAndKeyboardInput() async {
        let fixture = makeFixture("parity-unsupported", profile: { _ in Self.unsupportedProfile })

        await assertThrows(try await fixture.engine.click(coordinateClick()), code: "background_delivery_unavailable") { error in
            XCTAssertTrue(error.description.contains("Unity"), error.description)
        }
        await assertThrows(
            try await fixture.engine.key(KeyRequest(chord: "a", appIdentifier: "TargetApp")),
            code: "background_delivery_unavailable"
        )
        XCTAssertTrue(fixture.mouse.calls.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
    }

    func testViaAndForegroundOverrideAnUnsupportedProfile() async throws {
        let fixture = makeFixture("parity-unsupported-override", profile: { _ in Self.unsupportedProfile })

        let forced = try await fixture.engine.click(coordinateClick(via: .window))
        XCTAssertEqual(forced.deliveryMethod, .window)
        let foreground = try await fixture.engine.click(coordinateClick(foreground: true))
        XCTAssertEqual(foreground.deliveryMethod, .global)
        XCTAssertEqual(fixture.mouse.calls.map(\.destination), [.window(fixtureWindow), .global])
    }

    func testUnsupportedProfileStillTriesTheAXTier() async throws {
        let fixture = makeFixture("parity-unsupported-ax", records: [record("0.1", title: "Play", actions: ["AXPress"])], profile: { _ in Self.unsupportedProfile })

        let result = try await fixture.engine.click(ClickRequest(
            x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, button: .left,
            doubleClick: false, triple: false, primeClick: false, humanLike: false, modifiers: [],
            element: "Play", appIdentifier: "TargetApp"
        ))

        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(fixture.axActions.performedActions, ["AXPress"])
    }

    // MARK: sequence

    func testSequenceDecodesParitySteps() throws {
        let data = Data("""
        {"steps":[
            {"selectText":{"elementId":"0.2","app":"TargetApp","range":{"location":1,"length":3}}},
            {"selectText":{"element":"Name","text":"world"}},
            {"action":{"name":"AXShowMenu","elementId":"0.3","app":"TargetApp"}},
            {"launch":{"app":"Calculator","timeoutMS":5000}},
            {"scroll":{"element":"Content","direction":"down","pages":2}}
        ]}
        """.utf8)

        let steps = try JSONDecoder().decode(SequenceFile.self, from: data).steps
        XCTAssertEqual(steps.count, 5)
        guard case .selectText(let ranged) = steps[0], case .selectText(let matched) = steps[1],
              case .action(let action) = steps[2], case .launch(let launch) = steps[3],
              case .scroll(let scroll) = steps[4] else {
            return XCTFail("Unexpected step kinds")
        }
        XCTAssertEqual(ranged.range, AXTextRange(location: 1, length: 3))
        XCTAssertEqual(matched.text, "world")
        XCTAssertEqual(action.name, "AXShowMenu")
        XCTAssertEqual(launch.timeoutMs, 5000)
        XCTAssertEqual(scroll.direction, .down)
        XCTAssertEqual(scroll.pages, 2)
    }

    // MARK: doctor --app

    func testAppProfileUsesTheRunningAppsBundle() async throws {
        let catalog = FakeAppCatalog()
        let bundle = URL(fileURLWithPath: "/Applications/Target.app")
        catalog.bundleURLs[77] = bundle
        var asked: URL?
        let fixture = makeFixture("parity-profile-running", bundleProfile: { url in
            asked = url
            return BackgroundDeliveryProfile(toolkit: .electron, preferredTier: .focusAssisted, authenticatedKeyboard: true)
        }, catalog: catalog)

        let report = try await fixture.engine.appProfile(identifier: "TargetApp")

        XCTAssertEqual(asked, bundle)
        XCTAssertTrue(report.running)
        XCTAssertEqual(report.pid, 77)
        XCTAssertEqual(report.path, "/Applications/Target.app")
        XCTAssertEqual(report.profile.toolkit, .electron)
        XCTAssertTrue(fixture.mouse.allDestinations.isEmpty)
        XCTAssertTrue(fixture.keyboard.destinations.isEmpty)
    }

    func testAppProfileFallsBackToTheInstalledBundle() async throws {
        let fixture = makeFixture("parity-profile-installed", catalog: calculatorCatalog())
        fixture.targets.unknownAppIsNotFound = true

        let report = try await fixture.engine.appProfile(identifier: "Calculator")

        XCTAssertFalse(report.running)
        XCTAssertNil(report.pid)
        XCTAssertEqual(report.path, "/System/Applications/Calculator.app")
        XCTAssertEqual(report.bundleID, "com.apple.calculator")
    }
}

/// Targeting fixes from the background-delivery review: keys reach the named
/// window, coordinate hit tests see every layer, element actions address the
/// element's own window, foreground element clicks check what they hit, element
/// lookup honors `--window-id`, `state` never pairs one window's capture with
/// another's tree, and an unconfirmed AX press is never repeated as a click.
final class TargetingReviewEngineTests: XCTestCase {
    private static let app = ResolvedApp(pid: 77, name: "TargetApp", bundleID: "com.example.target")
    private static let terminal = ResolvedApp(pid: 12, name: "Terminal", bundleID: "com.apple.Terminal")
    /// A second window of the same app, over the first window's left part.
    private static let secondWindow = InputWindowTarget(pid: 77, windowID: 501, bounds: CGRect(x: 60, y: 210, width: 260, height: 200))

    private func fixture(
        _ name: String,
        windows: [InputWindowTarget] = [fixtureWindow, secondWindow],
        records: [AXElementRecord] = [],
        frontmost: ResolvedApp? = terminal,
        activateApp: @escaping (ResolvedApp) throws -> Void = { _ in },
        keyboardController: KeyboardControlling? = nil,
        keyWindows: KeyWindowReading? = nil
    ) -> InputEngineFixture {
        let made = makeInputEngineFixture(
            name,
            frontmostApp: { frontmost },
            activateApp: activateApp,
            windows: windows,
            keyboardController: keyboardController,
            keyWindows: keyWindows
        )
        made.targets.apps["TargetApp"] = Self.app
        made.targets.apps["77"] = Self.app
        made.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: records)
        return made
    }

    private func button(_ id: String, title: String = "Save", center: CGPoint, value: String? = nil) -> AXElementRecord {
        AXElementRecord(
            id: id, role: "AXButton", title: title, value: value, actions: ["AXPress"],
            boundsPoints: RectD(x: center.x - 20, y: center.y - 10, w: 40, h: 20)
        )
    }

    private func click(
        element: String? = "Save",
        elementID: String? = nil,
        windowID: UInt32? = nil,
        via: InputDeliveryMethod? = nil,
        foreground: Bool = false
    ) -> ClickRequest {
        var request = ClickRequest(
            x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil,
            button: .left, doubleClick: false, triple: false, primeClick: false, humanLike: false, modifiers: [],
            element: element, elementID: elementID, appIdentifier: "TargetApp", via: via, foreground: foreground
        )
        request.windowID = windowID
        return request
    }

    private func coordinateClick(x: Double, y: Double, app: String? = nil) -> ClickRequest {
        ClickRequest(
            x: x, y: y, coordinateSpace: .points, metadataPath: nil,
            button: .left, doubleClick: false, triple: false, primeClick: false, humanLike: false, modifiers: [],
            appIdentifier: app
        )
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (String) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, code, "\(error)", file: file, line: line)
            check(error.description)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: 1. Keys reach the named window

    private func keyboardFixture(_ name: String, apps: SimulatedApps, frontmost: ResolvedApp? = terminal) -> InputEngineFixture {
        apps.keyWindows[77] = 500
        return fixture(name, frontmost: frontmost, keyboardController: KeyboardController(poster: apps.poster()), keyWindows: apps)
    }

    func testTypeWithWindowIDReachesThatWindowWhileAnotherIsKey() async throws {
        let apps = SimulatedApps()
        let made = keyboardFixture("review-type-window", apps: apps)

        var request = TypeRequest(text: "hi", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp")
        request.windowID = 501
        let result = try await made.engine.type(request)

        XCTAssertEqual(apps.text(in: 501), "hi")
        XCTAssertEqual(apps.text(in: 500), "", "nothing lands in the window that was key")
        XCTAssertEqual(result.deliveryMethod, .focusAssisted, "plain window keys cannot change the key window")
        XCTAssertEqual(result.keyWindowID, 501)
        XCTAssertEqual(apps.records.map(\.focused), [true, false])
    }

    func testKeyWithWindowIDInTheFrontmostAppReachesThatWindow() async throws {
        let apps = SimulatedApps()
        apps.frontPid = 77
        let made = keyboardFixture("review-key-window-front", apps: apps, frontmost: Self.app)

        let result = try await made.engine.key(KeyRequest(chord: "x", appIdentifier: "TargetApp", windowID: 501))

        XCTAssertFalse(apps.keys.isEmpty)
        XCTAssertEqual(Set(apps.keys.map(\.windowID)), [501], "every key event landed in window 501")
        XCTAssertTrue(apps.records.isEmpty, "a frontmost app needs no focus record")
        XCTAssertEqual(result.keyWindowID, 501)
    }

    func testKeysWithWindowIDFailWhenTheWindowCannotBeMadeKey() async {
        let apps = SimulatedApps()
        apps.primerMakesKey = false
        let made = keyboardFixture("review-keys-window-unkeyable", apps: apps)

        await assertThrows(
            try await made.engine.keys(KeysRequest(steps: ["press:a"], appIdentifier: "TargetApp", windowID: 501)),
            code: "background_delivery_unavailable"
        ) { message in
            XCTAssertTrue(message.contains("window 500 is key"), message)
        }
        XCTAssertTrue(apps.keys.isEmpty, "no key went to the other window")
    }

    func testTypeWithoutAWindowKeepsTheKeyWindowAndReportsIt() async throws {
        let apps = SimulatedApps()
        let made = keyboardFixture("review-type-no-window", apps: apps)

        let result = try await made.engine.type(TypeRequest(text: "ok", delayMilliseconds: nil, inputMode: .unicode, appIdentifier: "TargetApp"))

        XCTAssertEqual(result.deliveryMethod, .window)
        XCTAssertEqual(apps.text(in: 500), "ok")
        XCTAssertEqual(result.keyWindowID, 500)
    }

    func testTypeIntoAnElementReachesTheElementsOwnWindow() async throws {
        let apps = SimulatedApps()
        let made = keyboardFixture("review-type-element-window", apps: apps)
        made.reader.treeResult = AXTreeResult(axPrimed: false, truncated: false, elements: [
            AXElementRecord(id: "1.3", role: "AXTextField", title: "Name", boundsPoints: RectD(x: 70, y: 220, w: 100, h: 20)),
        ])
        made.reader.rootWindows["1"] = 501
        made.axActions.text = ""

        let result = try await made.engine.type(
            TypeRequest(text: "hi", delayMilliseconds: nil, inputMode: .unicode, element: "Name", appIdentifier: "TargetApp")
        )

        XCTAssertEqual(apps.text(in: 501), "hi")
        XCTAssertEqual(apps.text(in: 500), "")
        XCTAssertEqual(result.keyWindowID, 501)
    }

    // MARK: 2. Coordinate hit tests at every layer

    func testUntargetedClickOnAPanelIsAddressedToThePanel() async throws {
        let panel = InputWindowTarget(pid: 77, windowID: 641, bounds: CGRect(x: 200, y: 260, width: 120, height: 80), layer: 3, ownerName: "TargetApp")
        let made = fixture("review-panel", windows: [panel, fixtureWindow])

        let result = try await made.engine.click(coordinateClick(x: 150, y: 100))

        XCTAssertEqual(made.mouse.calls.first?.destination, .window(panel), "the floating panel, not the document under it")
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testClickOnAnOpenPopUpMenuIsRefusedNotPassedDown() async {
        let menu = InputWindowTarget(pid: 77, windowID: 640, bounds: CGRect(x: 200, y: 260, width: 120, height: 80), layer: 101, ownerName: "TargetApp")
        let made = fixture("review-popup", windows: [menu, fixtureWindow])

        for app in [nil, "TargetApp"] {
            await assertThrows(try await made.engine.click(coordinateClick(x: 150, y: 100, app: app)), code: "background_delivery_unavailable") { message in
                XCTAssertTrue(message.contains("an open menu"), message)
                XCTAssertTrue(message.contains("--foreground"), message)
            }
        }
        XCTAssertTrue(made.mouse.calls.isEmpty, "neither the menu nor the document under it gets a click")
    }

    func testUntargetedClickOnTheDockGoesToTheDockNotTheWindowBelow() async throws {
        let dock = InputWindowTarget(pid: 30, windowID: 20, bounds: CGRect(x: 100, y: 450, width: 400, height: 50), layer: 20, ownerName: "Dock")
        let made = fixture("review-dock", windows: [dock, fixtureWindow])

        _ = try await made.engine.click(coordinateClick(x: 150, y: 270))

        XCTAssertEqual(made.mouse.calls.first?.destination, .window(dock))
    }

    func testTargetedClickUnderTheDockStillGoesToTheTargetApp() async throws {
        let dock = InputWindowTarget(pid: 30, windowID: 20, bounds: CGRect(x: 100, y: 450, width: 400, height: 50), layer: 20, ownerName: "Dock")
        let made = fixture("review-dock-targeted", windows: [dock, fixtureWindow])

        _ = try await made.engine.click(coordinateClick(x: 150, y: 270, app: "TargetApp"))

        XCTAssertEqual(made.mouse.calls.first?.destination, .window(fixtureWindow), "the named app gets it, whatever is on top")
    }

    func testUntargetedClickOnTheMenuBarOrAThumbnailIsRefusedNotPassedDown() async {
        let menuBar = InputWindowTarget(pid: 400, windowID: 3, bounds: CGRect(x: 0, y: 0, width: 1440, height: 210), layer: 24, ownerName: "Window Server")
        let thumbnail = InputWindowTarget(
            pid: 88, windowID: 9, bounds: CGRect(x: 100, y: 450, width: 100, height: 50),
            isOnScreen: false, isStageManagerThumbnail: true, ownerName: "Notes"
        )
        let made = fixture("review-menubar", windows: [menuBar, thumbnail, fixtureWindow])

        await assertThrows(try await made.engine.click(coordinateClick(x: 150, y: 5)), code: "background_delivery_unavailable") { message in
            XCTAssertTrue(message.contains("Window Server"), message)
            XCTAssertTrue(message.contains("--foreground"), message)
        }
        await assertThrows(try await made.engine.click(coordinateClick(x: 20, y: 270)), code: "background_delivery_unavailable") { message in
            XCTAssertTrue(message.contains("Stage Manager"), message)
        }
        XCTAssertTrue(made.mouse.calls.isEmpty, "never delivered to the window underneath")
    }

    func testUntargetedClickOnTheDesktopGoesToTheDesktopOwner() async throws {
        let desktop = InputWindowTarget(pid: 60, windowID: 2, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: -2147483603, ownerName: "Finder")
        let made = fixture("review-desktop", windows: [desktop])

        _ = try await made.engine.click(coordinateClick(x: 10, y: 10))

        XCTAssertEqual(made.mouse.calls.first?.destination, .window(desktop))
    }

    // MARK: 3. Element events go to the element's own window

    func testElementClickIsAddressedToTheElementsWindowNotTheTopmostOne() async throws {
        // The element lies outside both windows (scrolled away), so no hit test
        // can name its window; the old code fell back to the app's front window.
        let made = fixture("review-element-own-window", records: [button("1.2", center: CGPoint(x: 5, y: 5))])
        made.reader.rootWindows["1"] = 501
        made.axActions.performError = ScreenCommanderError.elementNotActionable("no press")

        let result = try await made.engine.click(click())

        XCTAssertEqual(made.mouse.calls.first?.destination, .window(Self.secondWindow))
        XCTAssertEqual(result.deliveryMethod, .window)
    }

    func testElementClickRefusesToClickThroughAnotherWindowOfTheSameApp() async {
        // Window 500 is in front and covers the element's point in window 501.
        let made = fixture("review-element-covered", records: [button("1.2", center: CGPoint(x: 150, y: 300))])
        made.reader.rootWindows["1"] = 501
        made.axActions.performError = ScreenCommanderError.elementNotActionable("no press")

        await assertThrows(try await made.engine.click(click()), code: "background_delivery_unavailable") { message in
            XCTAssertTrue(message.contains("covered by window 500"), message)
        }
        XCTAssertTrue(made.mouse.calls.isEmpty)
    }

    // MARK: 4. Foreground element clicks activate, raise, and check the point

    func testForegroundElementClickActivatesRaisesAndChecksThePoint() async throws {
        var activated: [pid_t] = []
        let other = InputWindowTarget(pid: 88, windowID: 700, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), ownerName: "Notes")
        let made = fixture(
            "review-foreground-click",
            windows: [other, fixtureWindow],
            records: [button("0.1", center: CGPoint(x: 300, y: 350))],
            activateApp: { activated.append($0.pid) }
        )
        let locator = made.windows
        made.axActions.onRaise = { _, windowID in locator.bringToFront(windowID) }
        // Raising reorders the app's windows, so the element's id now starts at 1.
        made.reader.elementAtResult = AXElementRecord(id: "1.1", role: "AXButton")
        made.reader.rootWindows["1"] = 500

        let result = try await made.engine.click(click(via: .global, foreground: true))

        XCTAssertEqual(activated, [77])
        XCTAssertEqual(made.axActions.raisedWindows.map(\.windowID), [500])
        XCTAssertEqual(made.mouse.calls.first?.destination, .global)
        XCTAssertEqual(made.mouse.calls.first?.point, CGPoint(x: 300, y: 350))
        XCTAssertEqual(result.deliveryMethod, .global)
    }

    func testForegroundElementClickRefusesWhenSomethingElseStillCoversThePoint() async {
        let other = InputWindowTarget(pid: 88, windowID: 700, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), ownerName: "Notes")
        let made = fixture("review-foreground-covered", windows: [other, fixtureWindow], records: [button("0.1", center: CGPoint(x: 300, y: 350))])

        await assertThrows(try await made.engine.click(click(via: .global, foreground: true)), code: "element_not_actionable") { message in
            XCTAssertTrue(message.contains("covered by window 700"), message)
        }
        XCTAssertTrue(made.mouse.calls.isEmpty)
    }

    func testForegroundElementClickRefusesWhenThePointHitsAnotherElement() async {
        let made = fixture("review-foreground-other-element", windows: [fixtureWindow], records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        made.reader.elementAtResult = AXElementRecord(id: "0.4", role: "AXPopover")

        await assertThrows(try await made.engine.click(click(via: .global, foreground: true)), code: "element_not_actionable") { message in
            XCTAssertTrue(message.contains("0.4"), message)
        }
        XCTAssertTrue(made.mouse.calls.isEmpty)
    }

    // MARK: 5. --element searches --window-id

    func testElementLookupSearchesTheNamedWindow() async throws {
        let made = fixture("review-element-window-id", records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        made.reader.windowTrees[501] = AXTreeResult(axPrimed: false, truncated: false, elements: [button("1.4", center: CGPoint(x: 75, y: 300))])
        made.reader.rootWindows["1"] = 501

        let clicked = try await made.engine.click(click(windowID: 501))
        XCTAssertEqual(clicked.element?.id, "1.4", "the Save button in window 501, not the focused window's")

        var typing = TypeRequest(text: "x", delayMilliseconds: nil, inputMode: .unicode, element: "Save", appIdentifier: "TargetApp")
        typing.windowID = 501
        let typed = try await made.engine.type(typing)
        XCTAssertEqual(typed.element?.id, "1.4")

        var scrolling = ScrollRequest(x: nil, y: nil, coordinateSpace: .pixels, metadataPath: nil, dx: 0, dy: -1, unit: .lines)
        scrolling.element = "Save"
        scrolling.appIdentifier = "TargetApp"
        scrolling.windowID = 501
        let scrolled = try await made.engine.scroll(scrolling)
        XCTAssertEqual(scrolled.element?.id, "1.4")

        let action = try await made.engine.performAction(PerformActionRequest(element: "Save", windowID: 501, name: "AXPress"))
        XCTAssertEqual(action.element.id, "1.4", "without --app, the window's owner is the app")

        XCTAssertTrue(made.reader.treeCalls.allSatisfy { $0.options.windowID == 501 })
    }

    func testElementIDOutsideTheNamedWindowIsRejected() async {
        let made = fixture("review-element-id-window", records: [button("0.1", center: CGPoint(x: 300, y: 350))])

        await assertThrows(try await made.engine.click(click(element: nil, elementID: "0.1", windowID: 501)), code: "invalid_arguments") { message in
            XCTAssertTrue(message.contains("is in window 500, not window 501"), message)
        }
    }

    // MARK: 8. An unconfirmed AX press is never repeated

    func testUnconfirmedPressIsNotRetriedAsAClick() async throws {
        let made = fixture("review-press-unconfirmed", records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        made.axActions.attemptResults = [.cannotComplete]

        let result = try await made.engine.click(click())

        XCTAssertTrue(made.mouse.calls.isEmpty, "the press may have run, so no event click follows")
        XCTAssertEqual(result.deliveryMethod, .ax)
        XCTAssertEqual(result.axError, "cannotComplete")
        XCTAssertEqual(result.verified, .unknown)
    }

    func testUnconfirmedPressThatChangedTheValueIsVerified() async throws {
        let made = fixture("review-press-unconfirmed-value", records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        made.axActions.readValueResult = "0"
        made.axActions.attemptResults = [.cannotComplete]
        made.axActions.valueAfterUnconfirmedAttempt = "1"

        let result = try await made.engine.click(click())

        XCTAssertTrue(made.mouse.calls.isEmpty)
        XCTAssertEqual(result.verified, .checked(true))
        XCTAssertEqual(result.axError, "cannotComplete")
    }

    func testRefusedPressFallsThroughAndAGoneElementStops() async throws {
        let refused = fixture("review-press-refused", records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        refused.axActions.attemptResults = [.actionUnsupported]
        let result = try await refused.engine.click(click())
        XCTAssertEqual(result.deliveryMethod, .window, "a refusal proves the press did not run")
        XCTAssertNil(result.axError)

        let gone = fixture("review-press-gone", records: [button("0.1", center: CGPoint(x: 300, y: 350))])
        gone.axActions.attemptResults = [.invalidUIElement]
        await assertThrows(try await gone.engine.click(click()), code: "element_not_actionable")
        XCTAssertTrue(gone.mouse.calls.isEmpty, "the old position now holds something else")
    }
}

extension ParityToolsEngineTests {
    func testStateNeverPairsTheCaptureWithAnotherWindowsTree() async {
        let records = [record("0", role: "AXWindow", title: "Focused doc", bounds: nil)]
        let fixture = makeFixture("parity-state-unmatched-window", records: records)
        // Accessibility cannot match the captured window 500; the focused window's
        // tree is some other window's.
        fixture.reader.windowTreeError = ScreenCommanderError.invalidArguments("App 'TargetApp' has no window with id 500.")

        await assertThrows(try await fixture.engine.appState(AppStateRequest(appIdentifier: "TargetApp")), code: "ax_tree_unavailable") { error in
            XCTAssertTrue(error.description.contains("window 500"), error.description)
        }
        XCTAssertTrue(fixture.reader.treeCalls.allSatisfy { $0.options.windowID == 500 }, "no read of the focused window instead")
    }
}
