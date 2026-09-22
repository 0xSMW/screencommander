// Decode one PNG/JPEG with ImageIO into fixed RGBA8. The benchmark compiles this
// helper once, then runs it only after each timed capture sequence has finished.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    fputs("capture pixel probe: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("expected one absolute image path") }
let path = CommandLine.arguments[1]
guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
    fail("image path must be an existing absolute file")
}
let url = URL(fileURLWithPath: path)
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("ImageIO could not decode image")
}
let width = image.width
let height = image.height
guard (1...20_000).contains(width), (1...20_000).contains(height),
      width <= Int.max / height / 4 else { fail("invalid image dimensions") }
let rowBytes = width * 4
var pixels = [UInt8](repeating: 0, count: rowBytes * height)
let drew = pixels.withUnsafeMutableBytes { memory -> Bool in
    guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drew else { fail("could not create RGBA8 context") }

func rgb(_ x: Int, _ y: Int) -> [Int] {
    let offset = (y * width + x) * 4
    return [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
}

let steps = [0.1, 0.25, 0.5, 0.75, 0.9]
let samples = steps.flatMap { y in
    steps.map { x in rgb(min(width - 1, Int(Double(width) * x)),
                         min(height - 1, Int(Double(height) * y))) }
}
let hash = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
let result: [String: Any] = [
    "width": width,
    "height": height,
    "rgbaSHA256": hash,
    "centerRGB": rgb(width / 2, height / 2),
    "sampleRGB": samples,
]
let json = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    ?? Data("{}".utf8)
print(String(data: json, encoding: .utf8) ?? "{}")
