import ApplicationServices
import CoreGraphics
import Foundation

protocol PermissionChecking {
    func ensureScreenRecordingAccess(prompt: Bool) throws
    func ensureAccessibilityAccess(prompt: Bool) throws
}

struct Permissions: PermissionChecking {
    func ensureScreenRecordingAccess(prompt: Bool = true) throws {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        if prompt {
            _ = CGRequestScreenCaptureAccess()
            if CGPreflightScreenCaptureAccess() {
                return
            }
        }

        throw ScreenCommanderError.permissionDeniedScreenRecording
    }

    func ensureAccessibilityAccess(prompt: Bool = true) throws {
        let isTrusted: Bool
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isTrusted = AXIsProcessTrusted()
        }

        guard isTrusted else {
            throw ScreenCommanderError.permissionDeniedAccessibility
        }
    }
}
