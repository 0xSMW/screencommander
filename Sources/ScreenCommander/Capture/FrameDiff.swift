import CoreGraphics
import Foundation

struct FrameDiffResult: Codable, Sendable {
    var changedFraction: Double
    var changedRegion: RectD?
}

struct FrameDiffConfig: Sendable, Equatable {
    static let defaultGrid = 64
    static let defaultThreshold = 0.04
    static let maximumGrid = 512

    var grid: Int
    var threshold: Double

    static let `default` = FrameDiffConfig(
        grid: FrameDiffConfig.defaultGrid,
        threshold: FrameDiffConfig.defaultThreshold
    )

    static func validated(grid: Int?, threshold: Double?) throws -> FrameDiffConfig {
        let grid = grid ?? defaultGrid
        let threshold = threshold ?? defaultThreshold

        guard (1...maximumGrid).contains(grid) else {
            throw ScreenCommanderError.invalidArguments("--diff-grid must be between 1 and \(maximumGrid).")
        }
        guard threshold.isFinite, (0...1).contains(threshold) else {
            throw ScreenCommanderError.invalidArguments("--diff-threshold must be between 0 and 1.")
        }

        return FrameDiffConfig(grid: grid, threshold: threshold)
    }
}

enum FrameDiff {
    static func compare(
        _ pre: CGImage,
        _ post: CGImage,
        grid requestedGrid: Int = 64,
        threshold: Double = 0.04
    ) -> FrameDiffResult {
        let postWidth = post.width
        let postHeight = post.height

        guard pre.width == postWidth, pre.height == postHeight else {
            return fullChange(width: postWidth, height: postHeight)
        }

        let grid = max(1, requestedGrid)
        let bytesPerPixel = 4
        let bytesPerRow = grid * bytesPerPixel
        var prePixels = [UInt8](repeating: 0, count: grid * grid * bytesPerPixel)
        var postPixels = [UInt8](repeating: 0, count: grid * grid * bytesPerPixel)

        guard draw(pre, into: &prePixels, grid: grid, bytesPerRow: bytesPerRow),
              draw(post, into: &postPixels, grid: grid, bytesPerRow: bytesPerRow) else {
            return fullChange(width: postWidth, height: postHeight)
        }

        var changedCells = 0
        var minCellX = grid
        var minCellY = grid
        var maxCellX = -1
        var maxCellY = -1

        for cellY in 0..<grid {
            for cellX in 0..<grid {
                let index = (cellY * grid + cellX) * bytesPerPixel
                let redDelta = abs(Int(prePixels[index]) - Int(postPixels[index]))
                let greenDelta = abs(Int(prePixels[index + 1]) - Int(postPixels[index + 1]))
                let blueDelta = abs(Int(prePixels[index + 2]) - Int(postPixels[index + 2]))
                let meanDelta = Double(redDelta + greenDelta + blueDelta) / (3.0 * 255.0)

                if meanDelta > threshold {
                    changedCells += 1
                    minCellX = min(minCellX, cellX)
                    minCellY = min(minCellY, cellY)
                    maxCellX = max(maxCellX, cellX)
                    maxCellY = max(maxCellY, cellY)
                }
            }
        }

        guard changedCells > 0 else {
            return FrameDiffResult(changedFraction: 0.0, changedRegion: nil)
        }

        let cellWidth = Double(postWidth) / Double(grid)
        let cellHeight = Double(postHeight) / Double(grid)
        let region = RectD(
            x: Double(minCellX) * cellWidth,
            y: Double(minCellY) * cellHeight,
            w: Double(maxCellX - minCellX + 1) * cellWidth,
            h: Double(maxCellY - minCellY + 1) * cellHeight
        )

        return FrameDiffResult(
            changedFraction: Double(changedCells) / Double(grid * grid),
            changedRegion: region
        )
    }

    static func compare(
        _ pre: CGImage,
        _ post: CGImage,
        config: FrameDiffConfig
    ) -> FrameDiffResult {
        compare(pre, post, grid: config.grid, threshold: config.threshold)
    }

    private static func draw(
        _ image: CGImage,
        into pixels: inout [UInt8],
        grid: Int,
        bytesPerRow: Int
    ) -> Bool {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        return pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: grid,
                    height: grid,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return true
        }
    }

    private static func fullChange(width: Int, height: Int) -> FrameDiffResult {
        FrameDiffResult(
            changedFraction: 1.0,
            changedRegion: RectD(x: 0, y: 0, w: Double(width), h: Double(height))
        )
    }
}
