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
        }
    }
}

func writeError(_ message: String) {
    guard let data = ("error: \(message)\n").data(using: .utf8) else {
        return
    }
    FileHandle.standardError.write(data)
}
