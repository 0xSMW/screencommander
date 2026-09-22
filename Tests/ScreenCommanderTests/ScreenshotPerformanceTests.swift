import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import ScreenCommander

final class ScreenshotPerformanceTests: XCTestCase {
    func testSingleEncodeWritesTheReturnedBytesForBothFormats() throws {
        let image = try generatedImage()
        for format in [ImageFormat.png, .jpeg] {
            let url = temporaryURL(format)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try ImageWriter().writeEncoded(image: image, format: format, to: url)
            let data = try XCTUnwrap(result.data)
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertEqual(result.pixelSize.w, Double(image.width))
            XCTAssertEqual(result.pixelSize.h, Double(image.height))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(try XCTUnwrap(CGImageSourceGetType(source)) as String, format.utTypeIdentifier as String)
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, image.width)
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.height, image.height)
        }
    }

    func testLegacyImageWriterStillSupportsEncodedMethod() throws {
        let image = try generatedImage()
        let url = temporaryURL(.png)
        let writer: ImageWriting = LegacyWriter()
        let result = try writer.writeEncoded(image: image, format: .png, to: url)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.pixelSize.w, Double(image.width))
    }

    func testTypedResponseMetadataPreservesErrorSemantics() {
        let successful = response(data: Data([0, 1, 2]))
        XCTAssertEqual(MCPServer.metadataPath(in: successful), "/tmp/screenshot-ab.json")
        var failed = successful
        failed.result = .object([
            "isError": .bool(true),
            "structuredContent": .object(["result": .object(["metadataPath": .string("/tmp/screenshot-ab.json")])]),
        ])
        XCTAssertNil(MCPServer.metadataPath(in: failed))
    }

    /// Reproducible local A/B: SCREENCOMMANDER_PERF_AB=1 swift test -c release
    /// --filter ScreenshotPerformanceTests. Alternates paths on the same generated
    /// image and reports wall p50/p95, total process CPU, and response bytes.
    func testScreenshotEncodingAndMetadataAB() throws {
        guard ProcessInfo.processInfo.environment["SCREENCOMMANDER_PERF_AB"] == "1" else { return }
        let image = try generatedImage(width: 960, height: 640)
        let writer = ImageWriter()
        let oldURL = temporaryURL(.png)
        let newURL = temporaryURL(.png)
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }

        var oldSamples: [Sample] = []
        var newSamples: [Sample] = []
        // Warm the encoders, then alternate order to reduce warm-up bias.
        for iteration in 0..<24 {
            let measured = iteration >= 4
            if iteration.isMultiple(of: 2) {
                let old = try legacyPath(image: image, url: oldURL)
                let new = try optimizedPath(image: image, url: newURL, writer: writer)
                if measured { oldSamples.append(old); newSamples.append(new) }
            } else {
                let new = try optimizedPath(image: image, url: newURL, writer: writer)
                let old = try legacyPath(image: image, url: oldURL)
                if measured { oldSamples.append(old); newSamples.append(new) }
            }
            XCTAssertEqual(try Data(contentsOf: oldURL), try Data(contentsOf: newURL))
        }
        let report: [String: Any] = [
            "fixture": "generated_960x640_png",
            "iterations": oldSamples.count,
            "warmups": 4,
            "old": sampleSummary(oldSamples),
            "new": sampleSummary(newSamples),
            "image_file_bytes": try Data(contentsOf: newURL).count,
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("SC_PERF_AB \(try XCTUnwrap(String(data: reportData, encoding: .utf8)))")
    }

    private struct Sample {
        var wall: Double
        var cpu: Double
        var responseBytes: Int
    }

    private func sampleSummary(_ samples: [Sample]) -> [String: Any] {
        let wall = samples.map(\.wall).sorted()
        let cpu = samples.map(\.cpu)
        return [
            "wall_p50_s": percentile(wall, 0.50),
            "wall_p95_s": percentile(wall, 0.95),
            "cpu_total_s": cpu.reduce(0, +),
            "response_bytes": samples[0].responseBytes,
        ]
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
    }

    private func legacyPath(image: CGImage, url: URL) throws -> Sample {
        let startWall = ProcessInfo.processInfo.systemUptime, startCPU = processCPU()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, ImageFormat.png.utTypeIdentifier, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let inMemory = NSMutableData()
        let memoryDestination = try XCTUnwrap(CGImageDestinationCreateWithData(inMemory as CFMutableData, ImageFormat.png.utTypeIdentifier, 1, nil))
        CGImageDestinationAddImage(memoryDestination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(memoryDestination))
        let response = try JSONRPCCodec.encode(response(data: inMemory as Data))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        XCTAssertEqual(parsed["result"]?["structuredContent"]?["result"]?["metadataPath"]?.stringValue, "/tmp/screenshot-ab.json")
        let sample = Sample(wall: ProcessInfo.processInfo.systemUptime - startWall, cpu: processCPU() - startCPU, responseBytes: response.utf8.count)
        XCTAssertEqual(try Data(contentsOf: url), inMemory as Data)
        return sample
    }

    private func optimizedPath(image: CGImage, url: URL, writer: ImageWriter) throws -> Sample {
        let startWall = ProcessInfo.processInfo.systemUptime, startCPU = processCPU()
        let encoded = try XCTUnwrap(writer.writeEncoded(image: image, format: .png, to: url).data)
        let value = response(data: encoded)
        let response = try JSONRPCCodec.encode(value)
        // Typed metadata is already available before the response becomes a string.
        XCTAssertEqual(MCPServer.metadataPath(in: value), "/tmp/screenshot-ab.json")
        return Sample(wall: ProcessInfo.processInfo.systemUptime - startWall, cpu: processCPU() - startCPU, responseBytes: response.utf8.count)
    }

    private func response(data: Data) -> JSONRPCResponse {
        let content = JSONValue.object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string("image/png")])
        let envelope = JSONValue.object(["status": .string("ok"), "command": .string("screenshot"), "result": .object(["metadataPath": .string("/tmp/screenshot-ab.json")])])
        let result = JSONValue.object(["content": .array([content]), "structuredContent": envelope, "isError": .bool(false)])
        return .success(id: .number(1), result: result)
    }

    private func processCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private func temporaryURL(_ format: ImageFormat) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screencommander-perf-\(UUID().uuidString).\(format.fileExtension)")
    }

    private func generatedImage(width: Int = 48, height: Int = 32) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(x % 255) / 255, CGFloat(y % 255) / 255, CGFloat((x + y) % 255) / 255, 1])!)
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }
}

private struct LegacyWriter: ImageWriting {
    func write(image: CGImage, format: ImageFormat, to url: URL) throws -> SizeD {
        SizeD(w: Double(image.width), h: Double(image.height))
    }
}
