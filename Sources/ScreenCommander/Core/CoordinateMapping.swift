import ArgumentParser
import CoreGraphics
import Foundation

enum CoordinateSpace: String, Codable, Sendable, ExpressibleByArgument {
    case pixels
    case points
    case normalized
}

struct ResolvedCoordinate: Codable, Sendable {
    var inputX: Double
    var inputY: Double
    var space: CoordinateSpace
    var globalX: Double
    var globalY: Double
}

struct CoordinateMapper {
    func map(x: Double, y: Double, space: CoordinateSpace, metadata: ScreenshotMetadata) throws -> ResolvedCoordinate {
        guard x.isFinite, y.isFinite else {
            throw ScreenCommanderError.invalidCoordinate("Coordinates must be finite numeric values.")
        }

        guard metadata.pointPixelScale > 0 else {
            throw ScreenCommanderError.mappingFailed("Metadata pointPixelScale must be greater than zero.")
        }

        let bounds = metadata.displayBoundsPoints
        let scale = metadata.pointPixelScale

        let dxPoints: Double
        let dyPoints: Double

        switch space {
        case .pixels:
            guard x >= 0, y >= 0, x < metadata.imageSizePixels.w, y < metadata.imageSizePixels.h else {
                throw ScreenCommanderError.invalidCoordinate("Pixel coordinate (\(x), \(y)) is outside image bounds \(metadata.imageSizePixels.w)x\(metadata.imageSizePixels.h).")
            }
            dxPoints = x / scale
            dyPoints = y / scale

        case .points:
            guard x >= 0, y >= 0, x < bounds.w, y < bounds.h else {
                throw ScreenCommanderError.invalidCoordinate("Point coordinate (\(x), \(y)) is outside display bounds \(bounds.w)x\(bounds.h).")
            }
            dxPoints = x
            dyPoints = y

        case .normalized:
            guard x >= 0, y >= 0, x < 1, y < 1 else {
                throw ScreenCommanderError.invalidCoordinate("Normalized coordinates must be in [0, 1).")
            }
            dxPoints = x * bounds.w
            dyPoints = y * bounds.h
        }

        let globalX = bounds.x + dxPoints
        let globalY = bounds.y + dyPoints

        let mappedX = globalX - bounds.x
        let mappedY = globalY - bounds.y
        guard mappedX >= 0, mappedY >= 0, mappedX < bounds.w, mappedY < bounds.h else {
            throw ScreenCommanderError.mappingFailed("Mapped coordinate \(globalX), \(globalY) is outside display bounds.")
        }

        return ResolvedCoordinate(
            inputX: x,
            inputY: y,
            space: space,
            globalX: globalX,
            globalY: globalY
        )
    }
}
