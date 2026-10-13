import AppKit
import CoreGraphics

/// What the cursor needs to know about the window it sits above.
struct TargetWindowInfo: Equatable {
    /// Global CG coordinates, top-left origin.
    var bounds: CGRect
    /// CG window level, which is also the `NSWindow.Level` raw value.
    var layer: Int
}

enum TargetWindowQuery {
    static func info(for windowID: UInt32) -> TargetWindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let entry = list.first,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return TargetWindowInfo(bounds: bounds, layer: layer)
    }

    /// True when the window is visible on the active Space. Minimized windows
    /// and windows on other Spaces are not in the list.
    static func isOnActiveSpace(_ windowID: UInt32) -> Bool {
        guard let numbers = NSWindow.windowNumbers(options: [.allApplications]) else {
            return false
        }
        return numbers.contains { $0.intValue == Int(windowID) }
    }

    /// Height of the primary display, for CG <-> Cocoa conversion.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    }
}
