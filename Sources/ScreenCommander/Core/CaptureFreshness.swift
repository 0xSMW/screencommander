import CoreGraphics
import Foundation

protocol MetadataFreshnessChecking {
    func freshness(for metadata: ScreenshotMetadata) -> MetadataFreshnessResult
}

final class MetadataFreshnessChecker: MetadataFreshnessChecking {
    private let displayBounds: (UInt32) -> CGRect?
    private let windowBounds: (UInt32) -> CGRect?
    private let tolerance: Double

    init(
        displayBounds: @escaping (UInt32) -> CGRect? = MetadataFreshnessChecker.liveDisplayBounds,
        windowBounds: @escaping (UInt32) -> CGRect? = MetadataFreshnessChecker.liveWindowBounds,
        tolerance: Double = 2
    ) {
        self.displayBounds = displayBounds
        self.windowBounds = windowBounds
        self.tolerance = tolerance
    }

    func freshness(for metadata: ScreenshotMetadata) -> MetadataFreshnessResult {
        if let windowID = metadata.windowID, let capturedWindowBounds = metadata.windowBoundsPoints {
            guard let liveBounds = windowBounds(windowID) else {
                return MetadataFreshnessResult(
                    status: .stale,
                    scope: "window",
                    reason: "Window \(windowID) is no longer present; recapture before using this metadata."
                )
            }
            guard approximatelyEqual(capturedWindowBounds.cgRect, liveBounds) else {
                return MetadataFreshnessResult(
                    status: .stale,
                    scope: "window",
                    reason: "Window \(windowID) moved or resized since capture; recapture before using this metadata."
                )
            }
        }

        guard let liveDisplayBounds = displayBounds(metadata.displayID) else {
            return MetadataFreshnessResult(
                status: .unknown,
                scope: "display",
                reason: "Display \(metadata.displayID) is not available in the live display snapshot."
            )
        }

        guard approximatelyEqual(metadata.displayBoundsPoints.cgRect, liveDisplayBounds) else {
            return MetadataFreshnessResult(
                status: .stale,
                scope: "display",
                reason: "Display \(metadata.displayID) geometry changed since capture; recapture before using this metadata."
            )
        }

        return MetadataFreshnessResult(
            status: .fresh,
            scope: metadata.windowID == nil ? "display" : "window",
            reason: "Captured metadata matches the current \(metadata.windowID == nil ? "display" : "window") geometry."
        )
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func liveDisplayBounds(displayID: UInt32) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }

        var displays = Array<CGDirectDisplayID>(repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }

        guard displays.contains(CGDirectDisplayID(displayID)) else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(displayID))
    }

    private static func liveWindowBounds(windowID: UInt32) -> CGRect? {
        let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]]

        guard let boundsDictionary = info?.first?[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &rect) else {
            return nil
        }
        return rect
    }
}
