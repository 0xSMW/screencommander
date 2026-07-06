import CoreGraphics
import Foundation
import XCTest
@testable import ScreenCommander

final class FrameDiffTests: XCTestCase {
    func testIdenticalImagesProduceNoChange() throws {
        let image = makeImage(width: 64, height: 64, fill: Pixel(r: 12, g: 34, b: 56))

        let result = FrameDiff.compare(image, image, grid: 16)

        XCTAssertEqual(result.changedFraction, 0.0)
        XCTAssertNil(result.changedRegion)
    }

    func testSingleChangedBlockProducesTightRegion() throws {
        let pre = makeImage(width: 128, height: 128, fill: Pixel(r: 255, g: 255, b: 255))
        let post = makeImage(
            width: 128,
            height: 128,
            fill: Pixel(r: 255, g: 255, b: 255),
            changedBlock: CGRect(x: 32, y: 48, width: 16, height: 16),
            changedFill: Pixel(r: 0, g: 0, b: 0)
        )

        let result = FrameDiff.compare(pre, post, grid: 16, threshold: 0.01)
        let region = try XCTUnwrap(result.changedRegion)
        let cellSize = 8.0

        XCTAssertGreaterThan(result.changedFraction, 0.0)
        XCTAssertLessThanOrEqual(result.changedFraction, 9.0 / 256.0)
        XCTAssertLessThanOrEqual(region.x, 32.0)
        XCTAssertLessThanOrEqual(region.y, 48.0)
        XCTAssertGreaterThanOrEqual(region.x + region.w, 48.0)
        XCTAssertGreaterThanOrEqual(region.y + region.h, 64.0)
        XCTAssertGreaterThanOrEqual(region.x, 32.0 - cellSize)
        XCTAssertGreaterThanOrEqual(region.y, 48.0 - cellSize)
        XCTAssertLessThanOrEqual(region.x + region.w, 48.0 + cellSize)
        XCTAssertLessThanOrEqual(region.y + region.h, 64.0 + cellSize)
    }

    func testFullDifferentImagesProduceFullChange() {
        let pre = makeImage(width: 32, height: 32, fill: Pixel(r: 0, g: 0, b: 0))
        let post = makeImage(width: 32, height: 32, fill: Pixel(r: 255, g: 255, b: 255))

        let result = FrameDiff.compare(pre, post, grid: 8)

        XCTAssertEqual(result.changedFraction, 1.0)
        XCTAssertEqual(result.changedRegion?.x, 0)
        XCTAssertEqual(result.changedRegion?.y, 0)
        XCTAssertEqual(result.changedRegion?.w, 32)
        XCTAssertEqual(result.changedRegion?.h, 32)
    }

    func testMismatchedSizesProduceFullPostshotRegion() {
        let pre = makeImage(width: 32, height: 32, fill: Pixel(r: 0, g: 0, b: 0))
        let post = makeImage(width: 48, height: 24, fill: Pixel(r: 255, g: 255, b: 255))

        let result = FrameDiff.compare(pre, post, grid: 8)

        XCTAssertEqual(result.changedFraction, 1.0)
        XCTAssertEqual(result.changedRegion?.x, 0)
        XCTAssertEqual(result.changedRegion?.y, 0)
        XCTAssertEqual(result.changedRegion?.w, 48)
        XCTAssertEqual(result.changedRegion?.h, 24)
    }

    func testRuntimeSkipsDiffWhenRequestedOrImageMissing() {
        let preImage = makeImage(width: 8, height: 8, fill: Pixel(r: 0, g: 0, b: 0))
        let postImage = makeImage(width: 8, height: 8, fill: Pixel(r: 255, g: 255, b: 255))
        let pre = ActionScreenshotCapture(
            result: ActionScreenshotResult(imagePath: "/tmp/pre.png", metadataPath: "/tmp/pre.json"),
            image: preImage
        )
        let post = ActionScreenshotCapture(
            result: ActionScreenshotResult(imagePath: "/tmp/post.png", metadataPath: "/tmp/post.json"),
            image: postImage
        )
        let missingImage = ActionScreenshotCapture(
            result: ActionScreenshotResult(imagePath: "/tmp/missing.png", metadataPath: "/tmp/missing.json"),
            image: nil
        )

        XCTAssertNil(CommandRuntime.frameDiff(pre: pre, post: post, skip: true))
        XCTAssertNil(CommandRuntime.frameDiff(pre: pre, post: missingImage, skip: false))
        XCTAssertEqual(CommandRuntime.frameDiff(pre: pre, post: post, skip: false)?.changedFraction, 1.0)
    }

    func testActionResultEnvelopeEncodesOptionalDiff() throws {
        let envelope = ActionResultEnvelope(
            action: KeyResult(normalizedChord: "enter"),
            preshot: nil,
            postshot: nil,
            diff: FrameDiffResult(
                changedFraction: 0.25,
                changedRegion: RectD(x: 1, y: 2, w: 3, h: 4)
            )
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let diff = try XCTUnwrap(object["diff"] as? [String: Any])
        let region = try XCTUnwrap(diff["changedRegion"] as? [String: Any])

        XCTAssertEqual(diff["changedFraction"] as? Double, 0.25)
        XCTAssertEqual(region["x"] as? Double, 1)
        XCTAssertEqual(region["y"] as? Double, 2)
        XCTAssertEqual(region["w"] as? Double, 3)
        XCTAssertEqual(region["h"] as? Double, 4)
    }
}

private struct Pixel {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

private func makeImage(
    width: Int,
    height: Int,
    fill: Pixel,
    changedBlock: CGRect? = nil,
    changedFill: Pixel? = nil
) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let inChangedBlock: Bool
            if let changedBlock {
                inChangedBlock = changedBlock.contains(CGPoint(x: x, y: y))
            } else {
                inChangedBlock = false
            }
            let pixel = inChangedBlock ? (changedFill ?? fill) : fill
            pixels[index] = pixel.r
            pixels[index + 1] = pixel.g
            pixels[index + 2] = pixel.b
            pixels[index + 3] = 255
        }
    }

    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)!
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big
        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
