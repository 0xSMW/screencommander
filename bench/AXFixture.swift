// Compile with: swiftc -framework Cocoa bench/AXFixture.swift -o /absolute/path/ax-fixture
// The only mutable state is this process's counter. SIGTERM restores the prior app
// when this fixture is still frontmost, then terminates cleanly.
import AppKit
import Darwin
import Foundation

final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var countLabel: NSTextField!
    private var count = 0
    private var previousApp: NSRunningApplication?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)

        let frame = NSRect(x: 120, y: 100, width: 1000, height: 700)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenCommander AX Benchmark Fixture"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let root = NSView(frame: frame)
        window.contentView = root

        let action = NSButton(frame: NSRect(x: 16, y: 650, width: 220, height: 30))
        action.title = "Increment fixture counter"
        action.setAccessibilityLabel("Increment fixture counter")
        action.target = self
        action.action = #selector(increment)
        root.addSubview(action)

        countLabel = NSTextField(labelWithString: "Fixture count: 0")
        countLabel.frame = NSRect(x: 250, y: 650, width: 220, height: 30)
        countLabel.setAccessibilityLabel("Fixture count")
        root.addSubview(countLabel)

        let checkbox = NSButton(checkboxWithTitle: "Sparse target checkbox", target: nil, action: nil)
        checkbox.frame = NSRect(x: 500, y: 650, width: 210, height: 30)
        checkbox.setAccessibilityLabel("Sparse target checkbox")
        root.addSubview(checkbox)

        let slider = NSSlider(frame: NSRect(x: 730, y: 650, width: 190, height: 30))
        slider.setAccessibilityLabel("Sparse target slider")
        root.addSubview(slider)

        let controls = NSScrollView(frame: NSRect(x: 16, y: 316, width: 968, height: 320))
        controls.hasVerticalScroller = true
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 1250))
        for index in 0..<520 {
            let row = index / 10
            let column = index % 10
            let button = NSButton(frame: NSRect(
                x: CGFloat(column * 94), y: CGFloat(1226 - row * 24), width: 91, height: 23
            ))
            button.title = "Cell \(String(format: "%03d", index))"
            button.setAccessibilityLabel("Fixture cell \(index)")
            button.bezelStyle = .recessed
            grid.addSubview(button)
        }
        controls.documentView = grid
        root.addSubview(controls)

        let document = NSScrollView(frame: NSRect(x: 16, y: 16, width: 968, height: 286))
        document.hasVerticalScroller = true
        document.hasHorizontalScroller = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 950, height: 280))
        text.string = String(repeating: "Benchmark document sentence 0123456789.\n", count: 3_500)
        text.isEditable = false
        text.setAccessibilityLabel("Fixture large document")
        document.documentView = text
        root.addSubview(document)

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("READY {\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"controls\":520,\"documentCharacters\":\(text.string.count)}")
        fflush(stdout)
    }

    @objc private func increment(_ sender: NSButton) {
        count += 1
        countLabel.stringValue = "Fixture count: \(count)"
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApp, !previousApp.isTerminated {
            _ = previousApp.activate()
        }
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
