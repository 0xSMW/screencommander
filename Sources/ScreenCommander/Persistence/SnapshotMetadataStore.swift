import Foundation

protocol SnapshotMetadataStoring {
    var defaultLastMetadataURL: URL { get }
    func save(metadata: ScreenshotMetadata, at metadataURL: URL, updateLastAt lastURL: URL?) throws
    func load(from metadataURL: URL) throws -> ScreenshotMetadata
}

final class SnapshotMetadataStore: SnapshotMetadataStoring {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lastMetadataURL: URL

    init(fileManager: FileManager = .default, lastMetadataURL: URL? = nil) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
        self.lastMetadataURL = lastMetadataURL
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("last-screenshot.json", isDirectory: false)
    }

    var defaultLastMetadataURL: URL {
        lastMetadataURL
    }

    func save(metadata: ScreenshotMetadata, at metadataURL: URL, updateLastAt lastURL: URL?) throws {
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            throw ScreenCommanderError.metadataFailure("Unable to encode metadata JSON: \(error.localizedDescription)")
        }

        do {
            try ensureParentDirectoryExists(for: metadataURL)
            try data.write(to: metadataURL, options: .atomic)

            if let lastURL, lastURL.standardizedFileURL != metadataURL.standardizedFileURL {
                try ensureParentDirectoryExists(for: lastURL)
                try data.write(to: lastURL, options: .atomic)
            }
        } catch {
            throw ScreenCommanderError.metadataFailure("Unable to write metadata file: \(error.localizedDescription)")
        }
    }

    func load(from metadataURL: URL) throws -> ScreenshotMetadata {
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw ScreenCommanderError.metadataFailure("Unable to read metadata at \(metadataURL.path): \(error.localizedDescription)")
        }

        do {
            return try decoder.decode(ScreenshotMetadata.self, from: data)
        } catch {
            throw ScreenCommanderError.metadataFailure("Unable to decode metadata JSON at \(metadataURL.path): \(error.localizedDescription)")
        }
    }

    private func ensureParentDirectoryExists(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
