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
    func drag(
        from start: CGPoint,
        to end: CGPoint,
        button: MouseButtonChoice,
        steps: Int,
        durationMS: Int,
        destination: MouseEventDestination
    ) throws
    func move(to point: CGPoint, destination: MouseEventDestination) throws
}

/// Builds mouse events and hands them to an `InputEventPosting` backend.
///
/// Every event comes from a private-state source with explicit flags, so modifiers
/// the user is physically holding never leak into synthesized input. Window and
/// focus-assisted destinations are stamped with the target window and pid and carry
/// a window-local location.
final class MouseController: MouseControlling {
    private let poster: InputEventPosting

    init(poster: InputEventPosting = LiveInputEventPoster()) {
        self.poster = poster
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
        let source = try makeEventSource()
        let flags = try MouseModifiers.flags(for: modifiers)
        try poster.prepare(destination)
        defer { poster.finish(destination) }

        if primeClick || humanLike {
            // `--prime` and human-like mode both mean "settle the pointer before
            // clicking"; stack them as one move so callers do not get two
            // indistinguishable pre-click motion events.
            try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: 0, flags: flags, source: source, destination: destination)
            usleep(humanLike ? 90_000 : 80_000)
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
        let source = try makeEventSource()
        try poster.prepare(destination)
        defer { poster.finish(destination) }
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
        event.flags = []
        if let target = destination.windowTarget {
            try WindowEventStamper.stamp(event, target: target, point: point, button: .left, clickState: 0)
        }
        poster.post(event, to: destination, kind: .mouse)
    }

    func drag(
        from start: CGPoint,
        to end: CGPoint,
        button: MouseButtonChoice,
        steps: Int,
        durationMS: Int,
        destination: MouseEventDestination
    ) throws {
        let source = try makeEventSource()
        try poster.prepare(destination)
        defer { poster.finish(destination) }
        try postMouseEvent(type: .mouseMoved, point: start, button: button.cgMouseButton, clickState: 0, flags: [], source: source, destination: destination)
        try postMouseEvent(type: button.mouseDownType, point: start, button: button.cgMouseButton, clickState: 1, flags: [], source: source, destination: destination)

        // Callers check the ranges (`InputLimits`). Clamp anyway, so no value can
        // overflow the conversion to microseconds or form an empty range.
        let steps = max(1, steps)
        let durationMS = min(max(0, durationMS), InputLimits.dragDurationMs.upperBound)
        let sleepPerStep = useconds_t(durationMS * 1_000 / steps)
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            try postMouseEvent(type: button.mouseDraggedType, point: point, button: button.cgMouseButton, clickState: 1, flags: [], source: source, destination: destination)
            if sleepPerStep > 0 {
                usleep(sleepPerStep)
            }
        }

        try postMouseEvent(type: button.mouseUpType, point: end, button: button.cgMouseButton, clickState: 1, flags: [], source: source, destination: destination)
    }

    func move(to point: CGPoint, destination: MouseEventDestination) throws {
        let source = try makeEventSource()
        try poster.prepare(destination)
        defer { poster.finish(destination) }
        try postMouseEvent(type: .mouseMoved, point: point, button: .left, clickState: 0, flags: [], source: source, destination: destination)
    }

    /// One click: a `mouseMoved` primer, then down, then up, with short gaps so the
    /// target processes each phase in order.
    private func postSingleClick(
        point: CGPoint,
        button: MouseButtonChoice,
        clickState: Int,
        flags: CGEventFlags,
        source: CGEventSource,
        destination: MouseEventDestination
    ) throws {
        try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
        usleep(12_000)
        try postMouseEvent(type: button.mouseDownType, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
        usleep(28_000)
        try postMouseEvent(type: button.mouseUpType, point: point, button: button.cgMouseButton, clickState: clickState, flags: flags, source: source, destination: destination)
    }

    private func postMouseEvent(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int,
        flags: CGEventFlags,
        source: CGEventSource,
        destination: MouseEventDestination
    ) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create mouse event for \(type).")
        }

        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.flags = flags
        if let target = destination.windowTarget {
            try WindowEventStamper.stamp(event, target: target, point: point, button: button, clickState: clickState)
        }
        poster.post(event, to: destination, kind: .mouse)
    }

    private func makeEventSource() throws -> CGEventSource {
        guard let source = SyntheticEventSource.make() else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create mouse event source.")
        }
        return source
    }
}
