import AppKit
import Foundation

/// `SCContentFilter(desktopIndependentWindow:)` requires an initialized
/// window-server (CGS) connection. GUI apps get one for free; a bare CLI process
/// asserts in `CGS_REQUIRE_INIT` without it. Touching `NSApplication.shared`
/// establishes the connection — no run loop or activation needed — but it must
/// happen on the main thread, and therefore BEFORE `AsyncBridge.run` blocks the
/// main thread on its semaphore (dispatching to the main queue from inside the
/// bridge deadlocks). Commands that can reach the window-capture path call this
/// first, synchronously, from their `run()`.
enum WindowServerConnection {
    private static var initialized = false

    static func ensureInitialized() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !initialized else {
            return
        }
        _ = NSApplication.shared
        initialized = true
    }
}
