import ApplicationServices
import CoreGraphics
import Foundation

struct DoctorPermissionStatus: Codable, Sendable {
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool
}

struct DoctorDisplayStatus: Codable, Sendable {
    var displayID: UInt32
    var isMain: Bool
    var boundsPoints: RectD
}

struct DoctorReport: Codable, Sendable {
    var permissions: DoctorPermissionStatus
    var displays: [DoctorDisplayStatus]
}

protocol DoctorReporting {
    func collect() throws -> DoctorReport
}

struct DoctorService: DoctorReporting {
    func collect() throws -> DoctorReport {
        let permissions = DoctorPermissionStatus(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )

        var count: UInt32 = 0
        let countStatus = CGGetActiveDisplayList(0, nil, &count)
        guard countStatus == .success else {
            throw ScreenCommanderError.captureFailed("Could not query active display count (\(countStatus.rawValue)).")
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listStatus = CGGetActiveDisplayList(count, &displayIDs, &count)
        guard listStatus == .success else {
            throw ScreenCommanderError.captureFailed("Could not query active displays (\(listStatus.rawValue)).")
        }

        let mainID = CGMainDisplayID()
        let displays = displayIDs.map { displayID in
            DoctorDisplayStatus(
                displayID: displayID,
                isMain: displayID == mainID,
                boundsPoints: RectD(CGDisplayBounds(displayID))
            )
        }

        return DoctorReport(permissions: permissions, displays: displays)
    }
}
