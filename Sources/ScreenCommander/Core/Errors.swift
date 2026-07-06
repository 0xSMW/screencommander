import Foundation

enum ScreenCommanderError: Error, CustomStringConvertible {
    case permissionDeniedScreenRecording
    case permissionDeniedAccessibility
    case captureFailed(String)
    case imageWriteFailed(String)
    case metadataFailure(String)
    case invalidCoordinate(String)
    case mappingFailed(String)
    case inputSynthesisFailed(String)
    case invalidArguments(String)
    case elementNotFound(String)
    case axTreeUnavailable(String)
    case elementNotActionable(String)
    case windowNotFound(String)
    case appNotFound(String)

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
        case .metadataFailure:
            return 30
        case .invalidCoordinate:
            return 40
        case .mappingFailed:
            return 41
        case .inputSynthesisFailed:
            return 50
        case .invalidArguments:
            return 60
        case .elementNotFound:
            return 70
        case .axTreeUnavailable:
            return 71
        case .elementNotActionable:
            return 72
        case .windowNotFound:
            return 80
        case .appNotFound:
            return 81
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
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .elementNotFound(let message):
            return "Element not found: \(message)"
        case .axTreeUnavailable(let message):
            return "Accessibility tree unavailable: \(message)"
        case .elementNotActionable(let message):
            return "Element not actionable: \(message)"
        case .windowNotFound(let message):
            return "Window not found: \(message)"
        case .appNotFound(let message):
            return "App not found: \(message)"
        }
    }

    /// Stable snake_case code for JSON error envelope; detail goes in `message`.
    var stableCode: String {
        switch self {
        case .permissionDeniedScreenRecording: return "permission_denied_screen_recording"
        case .permissionDeniedAccessibility: return "permission_denied_accessibility"
        case .captureFailed: return "capture_failed"
        case .imageWriteFailed: return "image_write_failed"
        case .metadataFailure: return "metadata_failure"
        case .invalidCoordinate: return "invalid_coordinate"
        case .mappingFailed: return "mapping_failed"
        case .inputSynthesisFailed: return "input_synthesis_failed"
        case .invalidArguments: return "invalid_arguments"
        case .elementNotFound: return "element_not_found"
        case .axTreeUnavailable: return "ax_tree_unavailable"
        case .elementNotActionable: return "element_not_actionable"
        case .windowNotFound: return "window_not_found"
        case .appNotFound: return "app_not_found"
        }
    }
}

func writeError(_ message: String) {
    guard let data = ("error: \(message)\n").data(using: .utf8) else {
        return
    }
    FileHandle.standardError.write(data)
}
