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

    func ensureDirectoriesExist(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: capturesDirectoryURL, withIntermediateDirectories: true)
    }
}
