import CoreGraphics
import Foundation
import ScreenCaptureKit

/// WindowServer reads avoid a second expensive ScreenCaptureKit enumeration
/// while detecting geometry changes during the shared-content cache lifetime.
enum CaptureGeometry {
    static func matches(frame: CGRect, isOnScreen: Bool, currentInfo: [String: Any]?) -> Bool {
        guard let currentInfo,
              let bounds = currentInfo[kCGWindowBounds as String] as? [String: Any],
              let currentFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let currentOnScreen = currentInfo[kCGWindowIsOnscreen as String] as? Bool else {
            return false
        }
        return frame == currentFrame && isOnScreen == currentOnScreen
    }

    static func isCurrent(window: SCWindow, displays: [SCDisplay]) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]]
        return matches(frame: window.frame, isOnScreen: window.isOnScreen, currentInfo: info?.first)
            && displaysAreCurrent(displays)
    }

    static func displaysAreCurrent(_ displays: [SCDisplay]) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success,
              Set(ids.prefix(Int(count))) == Set(displays.map(\.displayID)) else { return false }
        return displays.allSatisfy { CGDisplayBounds($0.displayID) == $0.frame }
    }
}
