import Foundation

protocol CaptureRetentionManaging {
    func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult
}

struct CaptureRetentionManager: CaptureRetentionManaging {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func pruneCaptures(in directory: URL, olderThan: TimeInterval, now: Date) throws -> CleanupResult {
        var deletedCount = 0
        var deletedBytesApprox: Int64 = 0

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return CleanupResult(deletedCount: 0, deletedBytesApprox: 0)
        }

        let cutoff = now.timeIntervalSince1970 - olderThan
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])

        for fileURL in urls {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])

                if resourceValues.isDirectory == true {
                    continue
                }

                guard let ext = fileURL.pathExtension.lowercased() as String?, ["png", "jpeg", "jpg", "json"].contains(ext) else {
                    continue
                }

                guard let date = resourceValues.contentModificationDate, date.timeIntervalSince1970 < cutoff else {
                    continue
                }

                let size = resourceValues.fileSize.flatMap(Int64.init) ?? 0
                try fileManager.removeItem(at: fileURL)
                deletedCount += 1
                deletedBytesApprox += size
            } catch {
                continue
            }
        }

        return CleanupResult(deletedCount: deletedCount, deletedBytesApprox: deletedBytesApprox)
    }
}
