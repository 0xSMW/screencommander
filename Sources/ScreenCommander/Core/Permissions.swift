import ApplicationServices
import CoreGraphics
import Foundation

protocol PermissionChecking {
    func ensureScreenRecordingAccess(prompt: Bool) throws
    func ensureAccessibilityAccess(prompt: Bool) throws
}

final class Permissions: PermissionChecking {
    private let preflightScreenRecording: () -> Bool
    private let requestScreenRecording: () -> Bool
    private let accessibilityTrusted: () -> Bool
    private let requestAccessibilityTrust: () -> Bool
    private let lock = NSLock()

    private var attemptedScreenRecordingPrompt = false
    private var attemptedAccessibilityPrompt = false

    init(
        preflightScreenRecording: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenRecording: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: @escaping () -> Bool = {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.preflightScreenRecording = preflightScreenRecording
        self.requestScreenRecording = requestScreenRecording
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
    }

    func ensureScreenRecordingAccess(prompt: Bool = true) throws {
        if preflightScreenRecording() {
            return
        }

        if prompt, claimScreenRecordingPromptAttempt() {
            _ = requestScreenRecording()
            if preflightScreenRecording() {
                return
            }
        }

        throw ScreenCommanderError.permissionDeniedScreenRecording
    }

    func ensureAccessibilityAccess(prompt: Bool = true) throws {
        if accessibilityTrusted() {
            return
        }

        if prompt, claimAccessibilityPromptAttempt() {
            // The prompt call is not the authority; TCC state is. Re-check the
            // non-prompting trust API so later grants are picked up without
            // showing another dialog in long-lived serve sessions.
            _ = requestAccessibilityTrust()
            if accessibilityTrusted() {
                return
            }
        }

        throw ScreenCommanderError.permissionDeniedAccessibility
    }

    private func claimScreenRecordingPromptAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !attemptedScreenRecordingPrompt else {
            return false
        }
        attemptedScreenRecordingPrompt = true
        return true
    }

    private func claimAccessibilityPromptAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !attemptedAccessibilityPrompt else {
            return false
        }
        attemptedAccessibilityPrompt = true
        return true
    }
}
