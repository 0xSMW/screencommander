import AppKit
import QuartzCore

/// The borderless, click-through window that carries one session's cursor.
final class CursorWindow: NSWindow {
    static let title = "ScreenCommander Cursor"

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: CursorGeometry.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        title = Self.title
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllApplications]
        alphaValue = 0
    }

    /// AppKit would otherwise pull the window back inside the screen near edges
    /// and under the menu bar, moving the hotspot off its point.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One session's cursor: placement, glide, fade, z-order, and Space tracking.
/// Main thread only.
final class CursorOverlay: NSObject {
    static let fadeDuration: TimeInterval = 0.44
    /// After the target window moves, follow it every frame for this long.
    static let followWindow: CFTimeInterval = 0.5
    /// Level used when there is no target window.
    static let floatingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))

    let session: String
    let window = CursorWindow()
    private let art: CursorArtView
    private let tuning: CursorMotionTuning

    /// Current hotspot in global CG coordinates.
    private(set) var hotspot: CGPoint?
    private var targetWindowID: UInt32?
    /// Last seen origin of the target window, global CG.
    private var targetOrigin: CGPoint?
    /// Hotspot relative to `targetOrigin` (or global when there is no target window).
    private var localHotspot: CGPoint?
    private var motion: CursorMotion?
    private var waiters: [(timing: CursorMoveTiming, completion: (CursorMoveOutcome) -> Void)] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var followUntil: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?

    /// The session wants the cursor on screen.
    private var wantsVisible = false
    /// The cursor is faded in (or fading in).
    private var shown = false

    init(session: String, colorIndex: Int, tuning: CursorMotionTuning = CursorMotionTuning()) {
        self.session = session
        self.tuning = tuning
        self.art = CursorArtView(colorIndex: colorIndex)
        super.init()
        window.contentView = art
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.assertOrdering()
        }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    var windowNumber: UInt32? {
        window.windowNumber > 0 ? UInt32(window.windowNumber) : nil
    }

    func apply(state: CursorState) {
        art.apply(state: state)
    }

    func press(count: Int) {
        art.press(count: count)
    }

    func move(to point: CGPoint, windowID: UInt32?, timing: CursorMoveTiming, completion: @escaping (CursorMoveOutcome) -> Void) {
        interruptMotion()
        wantsVisible = true
        targetWindowID = windowID

        let info = windowID.flatMap(TargetWindowQuery.info(for:))
        targetOrigin = info?.bounds.origin
        let origin = targetOrigin ?? .zero
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)

        if let windowID, info == nil || !TargetWindowQuery.isOnActiveSpace(windowID) {
            // Target is closed, minimized, or on another Space. Park the cursor
            // where it belongs and stay hidden until the window comes back.
            localHotspot = local
            place(at: point)
            fadeOut()
            completion(outcome(point: point, arrived: true))
            return
        }

        guard let current = hotspot, shown else {
            // First appearance, or reappearing after a hide: fade in on the spot.
            localHotspot = local
            place(at: point)
            fadeIn()
            if timing == .finished {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak self] in
                    guard let self else { return }
                    completion(self.outcome(point: point, arrived: true))
                }
            } else {
                completion(outcome(point: point, arrived: true))
            }
            return
        }

        assertOrdering()
        let start = CGPoint(x: current.x - origin.x, y: current.y - origin.y)
        motion = CursorMotion(from: start, to: local, tuning: tuning)
        waiters.append((timing, completion))
        startDisplayLink()
    }

    /// Fades out and keeps the session's place for the next move.
    func hide() {
        wantsVisible = false
        interruptMotion()
        stopDisplayLink()
        fadeOut()
    }

    /// Fades out, then closes the window for good.
    func remove() {
        wantsVisible = false
        interruptMotion()
        stopDisplayLink()
        fadeOut { [window] in
            window.close()
        }
    }

    /// Periodic upkeep: follow the target window, track its Space, and keep
    /// the cursor ordered directly above it.
    func refresh() {
        guard wantsVisible else {
            return
        }
        guard let windowID = targetWindowID else {
            assertOrdering()
            return
        }
        guard let info = TargetWindowQuery.info(for: windowID), TargetWindowQuery.isOnActiveSpace(windowID) else {
            if shown {
                interruptMotion()
                stopDisplayLink()
                fadeOut()
            }
            return
        }
        if info.bounds.origin != targetOrigin {
            targetOrigin = info.bounds.origin
            if motion == nil, let localHotspot {
                place(at: CGPoint(x: info.bounds.origin.x + localHotspot.x, y: info.bounds.origin.y + localHotspot.y))
            }
            followUntil = CACurrentMediaTime() + Self.followWindow
            startDisplayLink()
        }
        if !shown {
            fadeIn()
        }
        assertOrdering(info: info)
    }

    // MARK: Motion

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let fallback = link.duration > 0 ? link.duration : 1.0 / 60
        let dt = min(max(lastTimestamp.map { now - $0 } ?? fallback, 0), 1.0 / 15)
        lastTimestamp = now

        if let windowID = targetWindowID, let info = TargetWindowQuery.info(for: windowID), info.bounds.origin != targetOrigin {
            targetOrigin = info.bounds.origin
            followUntil = now + Self.followWindow
        }
        let origin = targetOrigin ?? .zero

        if var current = motion {
            current.step(dt)
            motion = current
            let local = current.point
            place(at: CGPoint(x: origin.x + local.x, y: origin.y + local.y))
            let destination = CGPoint(x: origin.x + current.path.end.x, y: origin.y + current.path.end.y)
            if current.isCloseEnough {
                flushWaiters(timing: .closeEnough, point: destination, arrived: true)
            }
            if current.isFinished {
                motion = nil
                localHotspot = current.path.end
                place(at: destination)
                flushWaiters(timing: nil, point: destination, arrived: true)
            }
        } else if let localHotspot {
            place(at: CGPoint(x: origin.x + localHotspot.x, y: origin.y + localHotspot.y))
        }

        if motion == nil && now >= followUntil {
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else {
            return
        }
        lastTimestamp = nil
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Ends the current glide early. Waiting callers hear `arrived: false`.
    private func interruptMotion() {
        guard let current = motion else {
            return
        }
        motion = nil
        if let hotspot {
            let origin = targetOrigin ?? .zero
            localHotspot = CGPoint(x: hotspot.x - origin.x, y: hotspot.y - origin.y)
        }
        let origin = targetOrigin ?? .zero
        flushWaiters(timing: nil, point: CGPoint(x: origin.x + current.path.end.x, y: origin.y + current.path.end.y), arrived: false)
    }

    /// Completes waiters for one timing, or all of them when `timing` is nil.
    private func flushWaiters(timing: CursorMoveTiming?, point: CGPoint, arrived: Bool) {
        let ready = waiters.filter { timing == nil || $0.timing == timing }
        waiters.removeAll { timing == nil || $0.timing == timing }
        let result = outcome(point: point, arrived: arrived)
        for waiter in ready {
            waiter.completion(result)
        }
    }

    private func outcome(point: CGPoint, arrived: Bool) -> CursorMoveOutcome {
        CursorMoveOutcome(
            point: PresencePoint(x: Double(point.x), y: Double(point.y)),
            arrived: arrived,
            visible: shown,
            cursorWindowID: windowNumber
        )
    }

    // MARK: Window

    private func place(at point: CGPoint) {
        hotspot = point
        let placement = CursorGeometry.placement(forHotspotAt: point, primaryScreenHeight: TargetWindowQuery.primaryScreenHeight)
        window.setFrameOrigin(placement.windowOrigin)
        art.setArtOffset(placement.artOffset)
    }

    private func assertOrdering(info: TargetWindowInfo? = nil) {
        guard shown else {
            return
        }
        if let windowID = targetWindowID, let info = info ?? TargetWindowQuery.info(for: windowID) {
            let level = NSWindow.Level(rawValue: info.layer)
            if window.level != level {
                window.level = level
            }
            window.order(.above, relativeTo: Int(windowID))
        } else {
            if window.level != Self.floatingLevel {
                window.level = Self.floatingLevel
            }
            window.orderFrontRegardless()
        }
    }

    private func fadeIn() {
        let wasShown = shown
        shown = true
        if !wasShown && !window.isVisible {
            window.alphaValue = 0
        }
        assertOrdering()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            window.animator().alphaValue = 1
        }
    }

    private func fadeOut(then completion: (() -> Void)? = nil) {
        shown = false
        guard window.isVisible else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if let self, !self.shown {
                self.window.orderOut(nil)
            }
            completion?()
        })
    }
}

/// `PresenceCursorDriver` backed by real windows. Hops every call to the main thread.
public final class CursorOverlayController: PresenceCursorDriver {
    private let tuning: CursorMotionTuning
    private var overlays: [String: CursorOverlay] = [:]
    private let windowIDLock = NSLock()
    private var windowIDs: [String: UInt32] = [:]
    private var spaceObserver: NSObjectProtocol?

    public init(tuning: CursorMotionTuning = CursorMotionTuning()) {
        self.tuning = tuning
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    public func moveCursor(
        session: String,
        colorIndex: Int,
        state: CursorState,
        to point: PresencePoint,
        windowID: UInt32?,
        timing: CursorMoveTiming,
        completion: @escaping (CursorMoveOutcome) -> Void
    ) {
        onMain {
            let overlay = self.overlay(for: session, colorIndex: colorIndex)
            overlay.apply(state: state)
            overlay.move(to: CGPoint(x: point.x, y: point.y), windowID: windowID, timing: timing, completion: completion)
            self.recordWindowNumber(overlay)
        }
    }

    public func pressCursor(session: String, count: Int) {
        onMain {
            self.overlays[session]?.press(count: count)
        }
    }

    public func setCursorState(session: String, state: CursorState) {
        onMain {
            self.overlays[session]?.apply(state: state)
        }
    }

    public func hideCursor(session: String) {
        onMain {
            self.overlays[session]?.hide()
        }
    }

    public func removeCursor(session: String) {
        onMain {
            guard let overlay = self.overlays.removeValue(forKey: session) else {
                return
            }
            overlay.remove()
            self.windowIDLock.lock()
            self.windowIDs.removeValue(forKey: session)
            self.windowIDLock.unlock()
        }
    }

    public func overlayWindowIDs() -> [UInt32] {
        windowIDLock.lock()
        defer { windowIDLock.unlock() }
        return windowIDs.values.sorted()
    }

    /// Main thread.
    public func refresh() {
        for overlay in overlays.values {
            overlay.refresh()
        }
    }

    /// Main thread.
    public func removeAll() {
        for session in Array(overlays.keys) {
            overlays.removeValue(forKey: session)?.window.close()
        }
        windowIDLock.lock()
        windowIDs.removeAll()
        windowIDLock.unlock()
    }

    private func overlay(for session: String, colorIndex: Int) -> CursorOverlay {
        if let existing = overlays[session] {
            return existing
        }
        let overlay = CursorOverlay(session: session, colorIndex: colorIndex, tuning: tuning)
        overlays[session] = overlay
        return overlay
    }

    private func recordWindowNumber(_ overlay: CursorOverlay) {
        guard let number = overlay.windowNumber else {
            return
        }
        windowIDLock.lock()
        windowIDs[overlay.session] = number
        windowIDLock.unlock()
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
