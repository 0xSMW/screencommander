import ArgumentParser
import CoreGraphics
import Foundation

enum MouseButtonChoice: String, Codable, Sendable, ExpressibleByArgument {
    case left
    case right

    var cgMouseButton: CGMouseButton {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    var mouseDownType: CGEventType {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        }
    }

    var mouseUpType: CGEventType {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        }
    }
}

protocol MouseControlling {
    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        primeClick: Bool,
        humanLike: Bool
    ) throws
}

final class MouseController: MouseControlling {
    func click(
        at point: CGPoint,
        button: MouseButtonChoice,
        doubleClick: Bool,
        primeClick: Bool,
        humanLike: Bool
    ) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        if primeClick {
            try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: 0, source: source)
            usleep(80_000)
        }

        if humanLike {
            try postSingleClick(point: point, button: button, clickState: 1, source: source)
            usleep(90_000)
        }

        if doubleClick {
            try postSingleClick(point: point, button: button, clickState: 1, source: source)
            usleep(60_000)
            try postSingleClick(point: point, button: button, clickState: 2, source: source)
        } else {
            try postSingleClick(point: point, button: button, clickState: 1, source: source)
        }
    }

    private func postSingleClick(
        point: CGPoint,
        button: MouseButtonChoice,
        clickState: Int,
        source: CGEventSource?
    ) throws {
        try postMouseEvent(type: .mouseMoved, point: point, button: button.cgMouseButton, clickState: clickState, source: source)
        try postMouseEvent(type: button.mouseDownType, point: point, button: button.cgMouseButton, clickState: clickState, source: source)
        try postMouseEvent(type: button.mouseUpType, point: point, button: button.cgMouseButton, clickState: clickState, source: source)
    }

    private func postMouseEvent(
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int,
        source: CGEventSource?
    ) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create mouse event for \(type).")
        }

        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }
}
