import ArgumentParser
import CoreGraphics
import Foundation

enum MouseButtonChoice: String, Codable, Sendable, ExpressibleByArgument {
    case left
    case right
    case middle

    var cgMouseButton: CGMouseButton {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .middle:
            return .center
        }
    }

    var mouseDownType: CGEventType {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        case .middle:
            return .otherMouseDown
        }
    }

    var mouseUpType: CGEventType {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        case .middle:
            return .otherMouseUp
        }
    }

    var mouseDraggedType: CGEventType {
        switch self {
        case .left:
            return .leftMouseDragged
        case .right:
            return .rightMouseDragged
        case .middle:
            return .otherMouseDragged
        }
    }
}

enum ScrollUnit: String, Codable, Sendable, ExpressibleByArgument {
    case lines
    case pixels

    var cgScrollUnit: CGScrollEventUnit {
        switch self {
        case .lines:
            return .line
        case .pixels:
            return .pixel
        }
    }
}

enum MouseModifiers {
    static func parse(_ raw: String?) throws -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return try normalized(raw.split(separator: ",").map(String.init))
    }

    static func normalized(_ modifiers: [String]) throws -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for modifier in modifiers {
            let value = modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else {
                continue
            }
            guard flagNameMap[value] != nil else {
                throw ScreenCommanderError.invalidArguments("Unsupported mouse modifier '\(modifier)'. Use cmd, shift, option, or ctrl.")
            }
            if seen.insert(value).inserted {
                normalized.append(value)
            }
        }

        return normalized
    }

    static func flags(for modifiers: [String]) throws -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in try normalized(modifiers) {
            if let flag = flagNameMap[modifier] {
                flags.insert(flag)
            }
        }
        return flags
    }

    private static let flagNameMap: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate,
        "ctrl": .maskControl
    ]
}

/// Where synthesized mouse events are posted.
///
/// `.global` posts to `.cghidEventTap` (moves the real cursor); `.pid` posts with
/// `CGEventPostToPid`, delivering the same events to one app while the user's cursor
/// stays put ("second mouse", WP5 tier `pid`).
enum MouseEventDestination: Equatable, Sendable {
    case global
    case pid(pid_t)
}

protocol MouseControlling {
    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String],
        destination: MouseEventDestination
    ) throws

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit, destination: MouseEventDestination) throws
    func drag(from start: CGPoint, to end: CGPoint, button: MouseButtonChoice, steps: Int, durationMS: Int) throws
    func move(to point: CGPoint) throws
}

extension MouseControlling {
    /// Global-delivery convenience overloads (the pre-WP5 surface).
    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String]
    ) throws {
        try click(
            at: point,
            button: button,
            doubleClick: doubleClick,
            tripleClick: tripleClick,
            primeClick: primeClick,
            humanLike: humanLike,
            modifiers: modifiers,
            destination: .global
        )
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit) throws {
        try scroll(at: point, dx: dx, dy: dy, unit: unit, destination: .global)
    }
}

final class MouseController: MouseControlling {
    private let postEvent: (CGEvent, MouseEventDestination) -> Void

    init(postEvent: @escaping (CGEvent, MouseEventDestination) -> Void = { event, destination in
        switch destination {
        case .global:
            event.post(tap: .cghidEventTap)
        case .pid(let pid):
            event.postToPid(pid)
        }
    }) {
        self.postEvent = postEvent
    }

    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        tripleClick: Bool,
        primeClick: Bool,
        humanLike: Bool,
        modifiers: [String],
        destination: MouseEventDestination
    ) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = try MouseModifiers.flags(for: modifiers)

        if primeClick {
            try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: 0, flags: flags, source: source, destination: destination)
            usleep(80_000)
        }

        if humanLike {
            // Human-like timing primes cursor position without spending a real click.
            // Focus belongs in the engine, where the target app/window is known and
            // can be activated before this exact click sequence is posted.
            try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: 0, flags: flags, source: source, destination: destination)
            usleep(90_000)
        }

        if tripleClick {
            try postSingleClick(point: point, button: button, clickState: 1, flags: flags, source: source, destination: destination)
            usleep(60_000)
            try postSingleClick(point: point, button: button, clickState: 2, flags: flags, source: source, destination: destination)
            usleep(60_000)
            try postSingleClick(point: point, button: button, clickState: 3, flags: flags, source: source, destination: destination)
        } else if doubleClick {
            try postSingleClick(point: point, button: button, clickState: 1, flags: flags, source: source, destination: destination)
            usleep(60_000)
            try postSingleClick(point: point, button: button, clickState: 2, flags: flags, source: source, destination: destination)
        } else {
            try postSingleClick(point: point, button: button, clickState: 1, flags: flags, source: source, destination: destination)
        }
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, unit: ScrollUnit, destination: MouseEventDestination) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        try postMouseEvent(type: .mouseMoved, point: point, button: .left, clickState: 0, flags: [], source: source, destination: destination)

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: unit.cgScrollUnit,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create scroll event.")
        }

        event.location = point
        post(event, to: destination)
    }

    func drag(from start: CGPoint, to end: CGPoint, button: MouseButtonChoice, steps: Int, durationMS: Int) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        try postMouseEvent(type: .mouseMoved, point: start, button: button.cgMouseButton, clickState: 0, flags: [], source: source)
        try postMouseEvent(type: button.mouseDownType, point: start, button: button.cgMouseButton, clickState: 1, flags: [], source: source)

        let sleepPerStep = steps > 0 ? useconds_t(max(0, durationMS) * 1_000 / steps) : 0
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            try postMouseEvent(type: button.mouseDraggedType, point: point, button: button.cgMouseButton, clickState: 1, flags: [], source: source)
            if sleepPerStep > 0 {
                usleep(sleepPerStep)
            }
        }

        try postMouseEvent(type: button.mouseUpType, point: end, button: button.cgMouseButton, clickState: 1, flags: [], source: source)
    }

    func move(to point: CGPoint) throws {
        try postMouseEvent(type: .mouseMoved, point: point, button: .left, clickState: 0, flags: [], source: CGEventSource(stateID: .hidSystemState))
    }

    private func postSingleClick(
        point: CGPoint,
        button: MouseButtonChoice,
        clickState: Int,
        flags: CGEventFlags,
        source: CGEventSource?,
        destination: MouseEventDestination
    ) throws {
        try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
        try postMouseEvent(type: button.mouseDownType, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
        try postMouseEvent(type: button.mouseUpType, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
    }

    private func postMouseEvent(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int,
        flags: CGEventFlags,
        source: CGEventSource?,
        destination: MouseEventDestination = .global
    ) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create mouse event for \(type).")
        }

        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.flags = flags
        post(event, to: destination)
    }

    /// `.global` posts to the HID tap (moves the real cursor); `.pid` posts the same
    /// event to one process via `CGEventPostToPid` (cursor untouched).
    private func post(_ event: CGEvent, to destination: MouseEventDestination) {
        postEvent(event, destination)
    }
}
