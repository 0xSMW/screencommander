import Foundation

enum ScreenCommanderError: Error, CustomStringConvertible {
    case permissionDeniedScreenRecording
    case permissionDeniedAccessibility
    case captureFailed(String)
    case captureTimeout(String)
    case imageWriteFailed(String)
    case metadataFailure(String)
    case invalidCoordinate(String)
    case mappingFailed(String)
    case inputSynthesisFailed(String)
    case backgroundDeliveryUnavailable(String)
    case targetBusy(String)
    case abortedByUser(String)
    case userInterrupted(String)
    case invalidArguments(String)
    case elementNotFound(String)
    case axTreeUnavailable(String)
    case elementNotActionable(String)
    case observeTimeout(String)
    case windowNotFound(String)
    case windowMinimized(String)
    case appNotFound(String)
    case elementAmbiguous(String)
    case staleMetadata(String)

    var exitCode: Int32 {
        switch self {
        case .permissionDeniedScreenRecording:
            return 10
        case .permissionDeniedAccessibility:
            return 11
        case .captureFailed:
            return 20
        case .imageWriteFailed:
            return 21
        case .captureTimeout:
            return 22
        case .metadataFailure:
            return 30
        case .invalidCoordinate:
            return 40
        case .mappingFailed:
            return 41
        case .inputSynthesisFailed:
            return 50
        case .backgroundDeliveryUnavailable:
            return 51
        case .targetBusy:
            return 52
        case .abortedByUser:
            return 53
        case .userInterrupted:
            return 54
        case .invalidArguments:
            return 60
        case .elementNotFound:
            return 70
        case .axTreeUnavailable:
            return 71
        case .elementNotActionable:
            return 72
        case .observeTimeout:
            return 73
        case .windowNotFound:
            return 80
        case .appNotFound:
            return 81
        case .elementAmbiguous:
            return 82
        case .staleMetadata:
            return 83
        case .windowMinimized:
            return 84
        }
    }

    var description: String {
        switch self {
        case .permissionDeniedScreenRecording:
            return "Screen recording permission is required. Open System Settings > Privacy & Security > Screen Recording and allow your terminal app, then re-run. Deeplink: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .permissionDeniedAccessibility:
            return "Accessibility permission is required. Open System Settings > Privacy & Security > Accessibility and allow your terminal app, then re-run. Deeplink: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .captureFailed(let message):
            return "Screenshot capture failed: \(message)"
        case .captureTimeout(let message):
            return "Capture timed out: \(message) The window server did not answer in time. Retry, and run 'doctor' if it keeps happening."
        case .imageWriteFailed(let message):
            return "Image write failed: \(message)"
        case .metadataFailure(let message):
            return "Metadata read/write failed: \(message)"
        case .invalidCoordinate(let message):
            return "Invalid coordinate: \(message)"
        case .mappingFailed(let message):
            return "Coordinate mapping failed: \(message)"
        case .inputSynthesisFailed(let message):
            return "Input synthesis failed: \(message)"
        case .backgroundDeliveryUnavailable(let message):
            // Many reasons already name --foreground, so skip the repeat.
            let next = message.contains("--foreground")
                ? ""
                : " To use the real cursor and keyboard instead, pass --foreground."
            return "Background delivery unavailable: \(message)\(next)"
        case .targetBusy(let message):
            return "Target busy: \(message) Another agent session is driving this app. Retry when it is done, or pass the same --session if both belong to one agent."
        case .abortedByUser(let message):
            return "Stopped by the user: \(message) Agent input stays stopped until `screencommander resume` runs, so check with the user first."
        case .userInterrupted(let message):
            return "User interrupted: \(message) The user is working in this app. Retry once they stop."
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .elementNotFound(let message):
            return "Element not found: \(message)"
        case .axTreeUnavailable(let message):
            return "Accessibility tree unavailable: \(message)"
        case .elementNotActionable(let message):
            return "Element not actionable: \(message) Read the UI again with 'elements' or 'state' before retrying."
        case .observeTimeout(let message):
            return "Observation timed out: \(message)"
        case .windowNotFound(let message):
            return "Window not found: \(message)"
        case .windowMinimized(let message):
            // The capturer's message names the fixes: restore the window, or read its tree.
            return "Window minimized: \(message)"
        case .appNotFound(let message):
            return "App not found: \(message)"
        case .elementAmbiguous(let message):
            return "Element ambiguous: \(message)"
        case .staleMetadata(let message):
            return "Stale metadata: \(message)"
        }
    }

    /// The detail alone, without the category prefix `description` adds.
    var message: String {
        switch self {
        case .permissionDeniedScreenRecording, .permissionDeniedAccessibility:
            return description
        case .captureFailed(let message), .captureTimeout(let message), .imageWriteFailed(let message),
             .metadataFailure(let message), .invalidCoordinate(let message), .mappingFailed(let message),
             .inputSynthesisFailed(let message), .backgroundDeliveryUnavailable(let message), .targetBusy(let message),
             .abortedByUser(let message), .userInterrupted(let message), .invalidArguments(let message),
             .elementNotFound(let message), .axTreeUnavailable(let message), .elementNotActionable(let message),
             .observeTimeout(let message), .windowNotFound(let message), .windowMinimized(let message),
             .appNotFound(let message), .elementAmbiguous(let message), .staleMetadata(let message):
            return message
        }
    }

    /// Stable snake_case code for JSON error envelope; detail goes in `message`.
    var stableCode: String {
        switch self {
        case .permissionDeniedScreenRecording: return "permission_denied_screen_recording"
        case .permissionDeniedAccessibility: return "permission_denied_accessibility"
        case .captureFailed: return "capture_failed"
        case .captureTimeout: return "capture_timeout"
        case .imageWriteFailed: return "image_write_failed"
        case .metadataFailure: return "metadata_failure"
        case .invalidCoordinate: return "invalid_coordinate"
        case .mappingFailed: return "mapping_failed"
        case .inputSynthesisFailed: return "input_synthesis_failed"
        case .backgroundDeliveryUnavailable: return "background_delivery_unavailable"
        case .targetBusy: return "target_busy"
        case .abortedByUser: return "aborted_by_user"
        case .userInterrupted: return "user_interrupted"
        case .invalidArguments: return "invalid_arguments"
        case .elementNotFound: return "element_not_found"
        case .axTreeUnavailable: return "ax_tree_unavailable"
        case .elementNotActionable: return "element_not_actionable"
        case .observeTimeout: return "observe_timeout"
        case .windowNotFound: return "window_not_found"
        case .windowMinimized: return "window_minimized"
        case .appNotFound: return "app_not_found"
        case .elementAmbiguous: return "element_ambiguous"
        case .staleMetadata: return "stale_metadata"
        }
    }
}

func writeError(_ message: String) {
    guard let data = ("error: \(message)\n").data(using: .utf8) else {
        return
    }
    FileHandle.standardError.write(data)
}
