import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ScreenCaptureKitCapturer: ScreenCapturing {
    private let captureTimeout: TimeInterval
    private let minimizedCapture: (CGWindowID) -> CGImage?

    init(
        captureTimeout: TimeInterval = CaptureDeadline.defaultSeconds,
        minimizedCapture: @escaping (CGWindowID) -> CGImage? = PrivateAPI.captureWindowImage
    ) {
        self.captureTimeout = captureTimeout
        self.minimizedCapture = minimizedCapture
    }

    func capture(window: ResolvedWindow, includeCursor: Bool) async throws -> CapturedScreenshot {
        if window.isMinimized || window.isOffScreen {
            return try captureOffScreen(window)
        }
        guard let scWindow = window.scWindow else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) has no ScreenCaptureKit handle to capture."
            )
        }

        let windowFrame = scWindow.frame
        guard windowFrame.width.isFinite, windowFrame.height.isFinite,
              windowFrame.width >= 1, windowFrame.height >= 1 else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) reports an unusable frame \(windowFrame)."
            )
        }

        let displays: [SCDisplay]
        if let resolvedDisplays = window.displays {
            displays = resolvedDisplays
        } else {
            // Support callers that supply a handle without a resolver snapshot.
            do {
                displays = try await ShareableContentProvider.enumerate(onScreenWindowsOnly: true, timeout: captureTimeout).displays
            } catch let error as ScreenCommanderError {
                throw error
            } catch {
                throw ScreenCommanderError.captureFailed("Could not enumerate displays for window capture: \(error.localizedDescription)")
            }
        }

        let intersectingDisplays = displays.filter { $0.frame.intersects(windowFrame) }
        guard let display = Self.displayContaining(windowFrame, in: intersectingDisplays) else {
            throw ScreenCommanderError.captureFailed("Window \(window.info.windowID) is not on a capturable display.")
        }
        guard intersectingDisplays.count == 1 else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) spans multiple displays; "
                    + "window capture metadata requires one display scale."
            )
        }

        // Desktop-independent filter: captures the window's own contents regardless
        // of occlusion or z-order (a display filter + sourceRect crops the screen
        // region instead, bleeding whatever is on top into the image). For window
        // filters, `contentRect` can be infinite and `pointPixelScale` 0, so never
        // size the capture from the filter — use the window frame, and take the
        // scale from the containing display when the window filter's is unusable.
        // Requires the window-server connection established by
        // WindowServerConnection.ensureInitialized() — see that type for why this
        // cannot happen here (the CLI's main thread is blocked in AsyncBridge by
        // the time this code runs).
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        var pointPixelScale = Double(filter.pointPixelScale)
        if !pointPixelScale.isFinite || pointPixelScale < 1 {
            pointPixelScale = Double(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
        }
        if !pointPixelScale.isFinite || pointPixelScale < 1 {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) reports an unusable pointPixelScale."
            )
        }

        let widthPixels = (Double(windowFrame.width) * pointPixelScale).rounded()
        let heightPixels = (Double(windowFrame.height) * pointPixelScale).rounded()
        guard widthPixels.isFinite, heightPixels.isFinite,
              (1...65_536).contains(widthPixels), (1...65_536).contains(heightPixels) else {
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) computes an unusable capture size (\(widthPixels)x\(heightPixels))."
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(widthPixels)
        configuration.height = Int(heightPixels)
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await CaptureDeadline.run(seconds: captureTimeout, what: "Window \(window.info.windowID) capture") {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            }
        } catch let error as ScreenCommanderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
        }

        // Report the display actually containing the window so metadata's
        // displayID/displayBoundsPoints keep their documented semantics; the
        // window's full frame travels separately as windowBoundsPoints.
        return CapturedScreenshot(
            image: CaptureColor.tagged(image, displayID: display.displayID),
            displayID: display.displayID,
            displayBoundsPoints: display.frame,
            pointPixelScale: pointPixelScale,
            contentBoundsPoints: windowFrame
        )
    }

    /// The window server's own copy of a window that is not on screen (minimized,
    /// its app hidden, or on another Space). When that call is unavailable or returns
    /// nothing, it fails at once: `window_minimized` for a minimized window and
    /// `capture_failed` for the others.
    func captureOffScreen(_ window: ResolvedWindow) throws -> CapturedScreenshot {
        let frame = window.info.boundsPoints.cgRect
        let owner = window.info.appName.isEmpty ? "pid \(window.info.pid)" : "'\(window.info.appName)'"
        guard frame.width >= 1, frame.height >= 1, let image = minimizedCapture(window.info.windowID) else {
            if window.isMinimized {
                throw ScreenCommanderError.windowMinimized(
                    "Window \(window.info.windowID) of \(owner) is minimized and could not be captured. "
                        + "Restore it from the Dock, or read its tree with 'elements --all-windows'."
                )
            }
            throw ScreenCommanderError.captureFailed(
                "Window \(window.info.windowID) of \(owner) is not on screen (its app is hidden, or it is on another Space) "
                    + "and the window server returned no image of it. Read its tree with 'elements --all-windows'."
            )
        }
        let displayID: CGDirectDisplayID
        let displayBounds: CGRect
        if let display = window.displays.flatMap({ Self.displayContaining(frame, in: $0) }) {
            displayID = display.displayID
            displayBounds = display.frame
        } else {
            displayID = CGMainDisplayID()
            displayBounds = CGDisplayBounds(displayID)
        }
        return CapturedScreenshot(
            image: CaptureColor.tagged(image, displayID: displayID),
            displayID: displayID,
            displayBoundsPoints: displayBounds,
            pointPixelScale: Double(image.width) / Double(frame.width),
            contentBoundsPoints: frame
        )
    }

    /// Finds the ScreenCaptureKit display with the largest intersection against
    /// the window frame, for metadata and as the pixel-scale fallback.
    private static func displayContaining(_ rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        }.flatMap { display in
            display.frame.intersects(rect) ? display : nil
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    func capture(display: ResolvedDisplay, includeCursor: Bool) async throws -> CapturedScreenshot {
        // The agent cursor never appears in display captures. Relying on
        // `NSWindow.sharingType` is unreliable against ScreenCaptureKit.
        let filter = SCContentFilter(display: display.scDisplay, excludingWindows: display.excludedWindows)
        let contentRect = filter.contentRect
        let pointPixelScale = Double(filter.pointPixelScale)
        guard pointPixelScale.isFinite, pointPixelScale >= 1 else {
            throw ScreenCommanderError.captureFailed("Display \(display.displayID) reports an unusable pointPixelScale.")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(contentRect.width) * pointPixelScale).rounded()))
        configuration.height = max(1, Int((Double(contentRect.height) * pointPixelScale).rounded()))
        configuration.showsCursor = includeCursor

        let image: CGImage
        do {
            image = try await CaptureDeadline.run(seconds: captureTimeout, what: "Display \(display.displayID) capture") {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            }
        } catch let error as ScreenCommanderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenCommanderError.captureFailed("ScreenCaptureKit reported an error: \(error.localizedDescription)")
        }

        let displayBoundsPoints = CGRect(
            x: display.displayFramePoints.origin.x,
            y: display.displayFramePoints.origin.y,
            width: contentRect.width,
            height: contentRect.height
        )

        return CapturedScreenshot(
            image: CaptureColor.tagged(image, displayID: display.displayID),
            displayID: display.displayID,
            displayBoundsPoints: displayBoundsPoints,
            pointPixelScale: pointPixelScale,
            contentBoundsPoints: nil
        )
    }
}

// MARK: - Deadline

/// Bounds one ScreenCaptureKit call. A capture can hang without ever returning
/// (a minimized window is the known case) and cannot be cancelled, so on timeout
/// or task cancellation the caller is answered at once and the call is left to
/// finish, or not, on its own.
enum CaptureDeadline {
    static let defaultSeconds: TimeInterval = 5

    static func run<T>(
        seconds: TimeInterval,
        what: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        let work = Task {
            do {
                gate.finish(.success(try await operation()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
                    gate.finish(.failure(ScreenCommanderError.captureTimeout(
                        "\(what) did not finish within \(String(format: "%.1f", seconds)) s."
                    )))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    /// Resumes the caller once with whichever result arrives first.
    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var done = false

        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            guard let continuation else {
                pending = result
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }
}

// MARK: - Color

/// ScreenCaptureKit returns display pixels tagged DeviceRGB, which PNG readers
/// take for sRGB, so a P3 display's red reads back as (234, 51, 36). Tagging the
/// image with its display's profile makes the written file describe the pixels it
/// holds. Pixel values are never changed.
enum CaptureColor {
    static func tagged(
        _ image: CGImage,
        displayID: CGDirectDisplayID,
        displaySpace: (CGDirectDisplayID) -> CGColorSpace? = { CGDisplayCopyColorSpace($0) }
    ) -> CGImage {
        let isDeviceRGB = image.colorSpace.map { CFEqual($0, CGColorSpaceCreateDeviceRGB()) } ?? true
        guard isDeviceRGB,
              let space = displaySpace(displayID),
              space.model == .rgb,
              let tagged = image.copy(colorSpace: space) else {
            return image
        }
        return tagged
    }
}
