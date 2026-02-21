import Foundation

enum SystemKey: String, Codable, Sendable, CaseIterable {
    case volumeUp = "volumeup"
    case volumeDown = "volumedown"
    case mute
    case brightnessUp = "brightnessup"
    case brightnessDown = "brightnessdown"
    case launchpad
    case playPause = "playpause"
    case nextTrack = "nexttrack"
    case previousTrack = "previoustrack"

    var nxKeyCode: Int64 {
        switch self {
        case .volumeUp:
            return 0
        case .volumeDown:
            return 1
        case .mute:
            return 7
        case .brightnessUp:
            return 2
        case .brightnessDown:
            return 3
        case .launchpad:
            return 13
        case .playPause:
            return 16
        case .nextTrack:
            return 17
        case .previousTrack:
            return 18
        }
    }

    static func resolve(_ rawToken: String) -> SystemKey? {
        let token = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch token {
        case "volumeup", "volume_up", "volume-up", "volup", "upvolume":
            return .volumeUp
        case "volumedown", "volume_down", "volume-down", "voldown", "downvolume":
            return .volumeDown
        case "mute", "mut":
            return .mute
        case "brightnessup", "brightness_up", "brightness-up", "brightup", "upbrightness":
            return .brightnessUp
        case "brightnessdown", "brightness_down", "brightness-down", "brightdown", "downbrightness":
            return .brightnessDown
        case "launchpad", "launch_panel", "launch-panel", "launchpanel", "launch panel":
            return .launchpad
        case "playpause", "play_pause", "play-pause", "play", "pause", "mediakeyplaypause":
            return .playPause
        case "nexttrack", "next_track", "next-track", "next":
            return .nextTrack
        case "previoustrack", "previous_track", "previous-track", "previous", "prev", "pretrack":
            return .previousTrack
        default:
            return nil
        }
    }
}
