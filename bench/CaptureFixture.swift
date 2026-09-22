// Disposable AppKit source for bench/capture_ab.py. Compile with swiftc -framework Cocoa.
// stdin accepts one JSON command per line: marker(red|blue|black), resize, move, geometry.
import AppKit
import CoreGraphics
import Darwin
import Foundation

final class CaptureCanvas: NSView {
    var marker = "red" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        bounds.fill()
        let cell: CGFloat = 40
        for row in 0..<Int(ceil(bounds.height / cell)) {
            for column in 0..<Int(ceil(bounds.width / cell)) where (row + column) % 2 == 0 {
                NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
                NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                       width: cell, height: cell).fill()
            }
        }
        let markerRect = NSRect(x: bounds.midX - 100, y: bounds.midY - 100,
                                width: 200, height: 200)
        let markerColor: NSColor
        switch marker {
        case "black": markerColor = .black
        case "blue": markerColor = NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
        default: markerColor = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        }
        markerColor.setFill()
        markerRect.fill()
        NSColor.black.setFill()
        NSRect(x: 8, y: 8, width: 32, height: 32).fill()
    }
}

final class CaptureFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var canvas: CaptureCanvas!
    private var previousApp: NSRunningApplication?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 130, y: 130, width: 900, height: 680),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered,
                          defer: false)
        window.title = "ScreenCommander Capture Benchmark Fixture"
        window.isReleasedWhenClosed = false
        window.delegate = self
        canvas = CaptureCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source

        print("READY \(response(extra: ["pid": ProcessInfo.processInfo.processIdentifier]))")
        fflush(stdout)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard let self else { return }
                let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                DispatchQueue.main.sync {
                    let answer = self.perform(request ?? [:])
                    print(answer)
                    fflush(stdout)
                }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func perform(_ request: [String: Any]) -> String {
        switch request["command"] as? String {
        case "marker":
            guard let color = request["color"] as? String, ["red", "blue", "black"].contains(color) else {
                return response(extra: ["error": "color must be red, blue or black"])
            }
            canvas.marker = color
        case "resize":
            guard let width = request["width"] as? Double,
                  let height = request["height"] as? Double,
                  (500...1300).contains(width), (450...900).contains(height) else {
                return response(extra: ["error": "invalid size"])
            }
            window.setContentSize(NSSize(width: width, height: height))
        case "move":
            guard let dx = request["dx"] as? Double, let dy = request["dy"] as? Double,
                  abs(dx) <= 100, abs(dy) <= 100 else {
                return response(extra: ["error": "invalid move"])
            }
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx,
                                          y: window.frame.origin.y + dy))
        case "geometry":
            break
        default:
            return response(extra: ["error": "unknown command"])
        }
        window.displayIfNeeded()
        NSApp.updateWindows()
        return response(extra: ["status": "ok"])
    }

    private func response(extra: [String: Any]) -> String {
        let f = window.frame
        let c = window.contentRect(forFrameRect: f)
        var object: [String: Any] = [
            "marker": canvas.marker,
            "windowID": window.windowNumber,
            "frameCocoa": ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height],
            "contentCocoa": ["x": c.minX, "y": c.minY, "w": c.width, "h": c.height],
        ]
        if let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]],
           let bounds = windows.first?[kCGWindowBounds as String] as? [String: NSNumber],
           let x = bounds["X"], let y = bounds["Y"],
           let width = bounds["Width"], let height = bounds["Height"] {
            object["frameCG"] = ["x": x.doubleValue, "y": y.doubleValue,
                                 "w": width.doubleValue, "h": height.doubleValue]
        }
        object.merge(extra) { _, new in new }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApp, !previousApp.isTerminated { _ = previousApp.activate() }
    }
}

let app = NSApplication.shared
let fixture = CaptureFixture()
app.delegate = fixture
app.run()
