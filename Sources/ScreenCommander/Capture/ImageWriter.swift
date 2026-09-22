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
    func writeEncoded(image: CGImage, format: ImageFormat, to url: URL) throws -> (pixelSize: SizeD, data: Data?)
}

extension ImageWriting {
    // Existing test writers need not materialize encoded bytes.
    func writeEncoded(image: CGImage, format: ImageFormat, to url: URL) throws -> (pixelSize: SizeD, data: Data?) {
        (try write(image: image, format: format, to: url), nil)
    }
}

final class ImageWriter: ImageWriting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        try writeEncoded(image: image, format: format, to: url).pixelSize
    }

    func writeEncoded(image: CGImage, format: ImageFormat, to url: URL) throws -> (pixelSize: SizeD, data: Data?) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ScreenCommanderError.imageWriteFailed("Could not create output directory: \(error.localizedDescription)")
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, format.utTypeIdentifier, 1, nil) else {
            throw ScreenCommanderError.imageWriteFailed("Could not create image destination for \(format.rawValue).")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCommanderError.imageWriteFailed("Image destination failed to finalize for \(url.path).")
        }

        let data = encoded as Data
        do {
            try data.write(to: url)
        } catch {
            throw ScreenCommanderError.imageWriteFailed("Could not write image to \(url.path): \(error.localizedDescription)")
        }
        return (SizeD(w: Double(image.width), h: Double(image.height)), data)
    }
}
