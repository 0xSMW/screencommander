import CoreGraphics
import ImageIO
import XCTest
@testable import ScreenCommander

final class CaptureGeometryTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 30, width: 640, height: 480)

    private func info(_ frame: CGRect, visible: Bool = true) -> [String: Any] {
        [kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowIsOnscreen as String: visible]
    }

    func testUnchangedWindowCanReuseEnumeration() {
        XCTAssertTrue(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame)))
    }

    func testMovedResizedMinimizedAndClosedWindowsRequireRefresh() {
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame.offsetBy(dx: 1, dy: 0))))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(CGRect(x: 20, y: 30, width: 800, height: 480))))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame, visible: false)))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: nil))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: [:]))
    }
}

final class CaptureReliabilityTests: XCTestCase {
    // MARK: Deadline

    func testHungCaptureTimesOutWithCaptureTimeout() async {
        let started = Date()
        do {
            _ = try await CaptureDeadline.run(seconds: 0.05, what: "Window 7 capture") { () async throws -> Int in
                await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
            XCTFail("Expected capture_timeout")
        } catch {
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "capture_timeout")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 22)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCancellationAnswersBeforeAHungCaptureReturns() async {
        let started = Date()
        let task = Task {
            try await CaptureDeadline.run(seconds: 30, what: "Display 1 capture") { () async throws -> Int in
                await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCaptureWithinTheDeadlineReturnsItsValue() async throws {
        let value = try await CaptureDeadline.run(seconds: 5, what: "capture") { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The postshot hang seen live: the display listing never answered, before any
    /// capture deadline was armed.
    func testUnansweredWindowListingTimesOutWithCaptureTimeout() async {
        let provider = ShareableContentProvider(timeout: 0.05) { _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            throw CancellationError()
        }
        let started = Date()
        do {
            _ = try await provider.content(onScreenWindowsOnly: true)
            XCTFail("Expected capture_timeout")
        } catch {
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "capture_timeout", "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testActionCaptureThatNeverAnswersIsAbandonedAndRecorded() {
        let started = Date()
        let shot = CommandRuntime.captureActionScreenshot(prefix: "Postshot-hang-test", deadline: 0.1) { _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            throw CancellationError()
        }
        XCTAssertNil(shot)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(CommandRuntime.shotFailure("Postshot-hang-test")?.code, "capture_timeout")
        XCTAssertNil(CommandRuntime.shotFailure("Preshot-hang-test"))
    }

    func testActionEnvelopeReportsAMissingPostshot() throws {
        let envelope = ActionResultEnvelope(
            action: ["clicked": true],
            postshotError: ErrorDetail(code: "capture_timeout", message: "late")
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        XCTAssertNotNil(object?["action"])
        XCTAssertNil(object?["postshot"])
        XCTAssertEqual((object?["postshotError"] as? [String: Any])?["code"] as? String, "capture_timeout")
    }

    // MARK: Minimized windows

    private func minimizedWindow(width: Double = 400, height: Double = 300) -> ResolvedWindow {
        ResolvedWindow(
            info: WindowInfo(windowID: 208, title: "Doc", appName: "Fixture", pid: 4242,
                             boundsPoints: RectD(x: 60, y: 200, w: width, h: height), isOnScreen: false, layer: 0),
            scWindow: nil,
            isMinimized: true
        )
    }

    func testMinimizedWindowIsCapturedThroughTheWindowServer() throws {
        let image = try XCTUnwrap(Self.image(width: 800, height: 600, space: CGColorSpace(name: CGColorSpace.displayP3)!))
        var asked: [CGWindowID] = []
        let capturer = ScreenCaptureKitCapturer(minimizedCapture: { id in asked.append(id); return image })

        let captured = try capturer.captureOffScreen(minimizedWindow())

        XCTAssertEqual(asked, [208])
        XCTAssertEqual(captured.pointPixelScale, 2)
        XCTAssertEqual(captured.contentBoundsPoints, CGRect(x: 60, y: 200, width: 400, height: 300))
        XCTAssertEqual(captured.image.width, 800)
    }

    func testHiddenOrOtherSpaceWindowIsCapturedThroughTheWindowServer() async throws {
        let image = try XCTUnwrap(Self.image(width: 800, height: 600, space: CGColorSpace(name: CGColorSpace.displayP3)!))
        var asked: [CGWindowID] = []
        let capturer = ScreenCaptureKitCapturer(minimizedCapture: { id in asked.append(id); return image })
        var window = minimizedWindow()
        window.isMinimized = false
        window.isOffScreen = true

        let captured = try await capturer.capture(window: window, includeCursor: false)

        XCTAssertEqual(asked, [208])
        XCTAssertEqual(captured.image.width, 800)
        XCTAssertEqual(captured.contentBoundsPoints, CGRect(x: 60, y: 200, width: 400, height: 300))
    }

    func testOffScreenWindowFailsFastWithCaptureFailedWhenTheWindowServerHasNothing() async {
        let capturer = ScreenCaptureKitCapturer(minimizedCapture: { _ in nil })
        var window = minimizedWindow()
        window.isMinimized = false
        window.isOffScreen = true
        let started = Date()
        do {
            _ = try await capturer.capture(window: window, includeCursor: false)
            XCTFail("Expected capture_failed")
        } catch {
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "capture_failed")
            XCTAssertTrue("\(error)".contains("not on screen"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testMinimizedWindowFailsFastWhenTheWindowServerHasNothing() async {
        let capturer = ScreenCaptureKitCapturer(minimizedCapture: { _ in nil })
        let started = Date()
        do {
            _ = try await capturer.capture(window: minimizedWindow(), includeCursor: false)
            XCTFail("Expected window_minimized")
        } catch {
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "window_minimized")
            XCTAssertEqual((error as? ScreenCommanderError)?.exitCode, 84)
            XCTAssertTrue("\(error)".contains("is minimized"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: Color

    func testDeviceRGBCaptureIsTaggedWithTheDisplayProfileWithoutTouchingPixels() throws {
        let device = try XCTUnwrap(Self.image(width: 2, height: 2, space: CGColorSpaceCreateDeviceRGB()))
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

        let tagged = CaptureColor.tagged(device, displayID: 1, displaySpace: { _ in p3 })

        XCTAssertEqual(tagged.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(Self.bytes(of: tagged), Self.bytes(of: device))

        let srgb = try XCTUnwrap(Self.image(width: 2, height: 2, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        XCTAssertEqual(CaptureColor.tagged(srgb, displayID: 1, displaySpace: { _ in p3 }).colorSpace?.name, CGColorSpace.sRGB,
                       "an image that already names its space keeps it")
    }

    func testWriterEmbedsTheImageProfileSoPixelsRoundTrip() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = try XCTUnwrap(Self.image(width: 4, height: 4, space: p3))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencommander-color-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try ImageWriter().write(image: image, format: .png, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyProfileName as String] as? String, "Display P3")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = Self.bytes(of: decoded)
        XCTAssertEqual(Array(pixels.prefix(3)), [255, 0, 0], "the stored values are the P3 values that were written")
    }

    /// Opaque red in `space`, 8-bit RGBA.
    private static func image(width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 255
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func bytes(of image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return Array(data as Data)
    }
}
