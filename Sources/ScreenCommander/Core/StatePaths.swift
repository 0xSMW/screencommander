import Darwin
import Foundation

struct StatePaths: Sendable {
    let stateDirectoryURL: URL
    let capturesDirectoryURL: URL
    let lastMetadataURL: URL

    init(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let override = environment["SCREENCOMMANDER_STATE_DIR"]
            .map { NSString(string: $0).expandingTildeInPath }

        let home = fileManager.homeDirectoryForCurrentUser

        if let overridePath = override, !overridePath.isEmpty {
            let base: URL
            if overridePath.hasPrefix("/") {
                base = URL(fileURLWithPath: overridePath, isDirectory: true)
            } else {
                base = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent(overridePath, isDirectory: true)
            }

            stateDirectoryURL = base
        } else {
            stateDirectoryURL = home
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
                .appendingPathComponent("screencommander")
        }

        capturesDirectoryURL = stateDirectoryURL.appendingPathComponent("captures", isDirectory: true)
        lastMetadataURL = stateDirectoryURL.appendingPathComponent("last-screenshot.json", isDirectory: false)
    }

    /// Unix socket the presence process listens on: `presence.sock` in the state
    /// directory, or a short fallback when that path is too long for a socket.
    var presenceSocketURL: URL {
        URL(fileURLWithPath: Self.presenceSocketPath(stateDirectory: stateDirectoryURL.standardizedFileURL.path), isDirectory: false)
    }

    /// Where the presence process (or a client that could not start it) records
    /// why it failed to start, for `doctor`. Removed when presence starts.
    var presenceStartErrorURL: URL {
        stateDirectoryURL.appendingPathComponent("presence-start-error.txt", isDirectory: false)
    }

    /// `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    static let maximumSocketPathBytes = 103

    /// The preferred socket path when it fits, otherwise
    /// `<temporaryRoot>/screencommander-<uid>/presence-<hash>.sock`, where the hash
    /// is a stable FNV-1a digest of the state directory. Every process computes the
    /// same path from the same state directory and user.
    static func presenceSocketPath(stateDirectory: String, uid: uid_t = getuid(), temporaryRoot: String = "/tmp") -> String {
        let preferred = (stateDirectory as NSString).appendingPathComponent("presence.sock")
        if preferred.utf8.count <= maximumSocketPathBytes {
            return preferred
        }
        return (presenceFallbackDirectory(uid: uid, temporaryRoot: temporaryRoot) as NSString)
            .appendingPathComponent("presence-\(stableHash(stateDirectory)).sock")
    }

    /// The per-user directory that holds fallback sockets.
    static func presenceFallbackDirectory(uid: uid_t = getuid(), temporaryRoot: String = "/tmp") -> String {
        (temporaryRoot as NSString).appendingPathComponent("screencommander-\(uid)")
    }

    /// 64-bit FNV-1a as 16 hex digits. `Hasher` is seeded per process, so it cannot be used here.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Cached per-app delivery classifications, one file per bundle ID and version.
    var profilesDirectoryURL: URL {
        stateDirectoryURL.appendingPathComponent("profiles", isDirectory: true)
    }

    func ensureDirectoriesExist(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: capturesDirectoryURL, withIntermediateDirectories: true)
    }
}
