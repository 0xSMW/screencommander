import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, Codable, Sendable, ExpressibleByArgument {
    case png
    case jpeg

    var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpeg:
            return "jpeg"
        }
    }

    var utTypeIdentifier: CFString {
        switch self {
        case .png:
            return UTType.png.identifier as CFString
        case .jpeg:
            return UTType.jpeg.identifier as CFString
        }
    }
}

protocol ImageWriting {
    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD
}

final class ImageWriter: ImageWriting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ScreenCommanderError.imageWriteFailed("Could not create output directory: \(error.localizedDescription)")
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utTypeIdentifier, 1, nil) else {
            throw ScreenCommanderError.imageWriteFailed("Could not create image destination for \(url.path).")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCommanderError.imageWriteFailed("Image destination failed to finalize for \(url.path).")
        }

        return SizeD(w: Double(image.width), h: Double(image.height))
    }
}
