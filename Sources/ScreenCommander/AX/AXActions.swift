import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation

/// How a synthesized input was (or should be) delivered.
///
/// - `ax`: `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` — coordinate-free,
///   works on background apps, never touches the real cursor.
/// - `pid`: CGEvents posted with `CGEventPostToPid` — screen-space coordinates, but the
///   user's cursor stays put. Some apps ignore posted events while unfocused; posting
///   success is the tier's contract, effect detection is the caller's job.
/// - `global`: CGEvents posted to `.cghidEventTap` — the classic path; moves the cursor.
enum InputDeliveryMethod: String, Codable, Sendable, ExpressibleByArgument, Equatable {
    case ax
    case pid
    case global
}

/// Coordinate-free AX actuation (WP5 tier `ax`), injected into the engine so tests can
/// fake it without a live Accessibility grant.
protocol AXActionPerforming {
    /// Performs a named AX action (`AXPress`, `AXShowMenu`, `AXConfirm`,
    /// `AXIncrement`, `AXDecrement`) on a live element.
    func perform(action: String, on element: AXElement) throws

    /// Writes the element's `AXValue` attribute directly (text fields, sliders, ...).
    func setValue(_ value: String, on element: AXElement) throws

    /// Focuses the element (`AXFocused = true`) — used before falling back to the
    /// keyboard path so keystrokes land in the intended field.
    func focus(on element: AXElement) throws
}

/// Production `AXActionPerforming` backed by live `AXUIElement` calls.
final class AXActions: AXActionPerforming {
    func perform(action: String, on element: AXElement) throws {
        let error = AXUIElementPerformAction(element.raw, action as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "AX action '\(action)' failed (\(Self.describe(error)))."
            )
        }
    }

    func setValue(_ value: String, on element: AXElement) throws {
        let error = element.setAttribute(kAXValueAttribute, value: value as CFString)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXValue failed (\(Self.describe(error)))."
            )
        }
    }

    func focus(on element: AXElement) throws {
        let error = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        guard error == .success else {
            throw ScreenCommanderError.elementNotActionable(
                "Setting AXFocused failed (\(Self.describe(error)))."
            )
        }
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .actionUnsupported: return "action unsupported"
        case .attributeUnsupported: return "attribute unsupported"
        case .cannotComplete: return "cannot complete — app may be busy or unresponsive"
        case .invalidUIElement: return "invalid element — the UI changed; re-read with 'elements'"
        case .notImplemented: return "not implemented by the app"
        case .apiDisabled: return "accessibility API disabled"
        case .failure: return "failure"
        default: return "AXError \(error.rawValue)"
        }
    }
}

/// Pure element matching for `--element "<title/label substring>"` (+ optional `--role`).
/// Matching is case-insensitive over `title`, `description`, and `value`. The best
/// match tier must be unique; ambiguous substring matches fail instead of silently
/// selecting tree order.
enum AXElementMatchResult {
    case found(AXElementRecord)
    case ambiguous([AXElementRecord])
}

enum AXElementMatcher {
    static func resolve(records: [AXElementRecord], query: String, role: String?) -> AXElementMatchResult? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }

        let roleFiltered = records.filter { roleMatches($0.role, filter: role) }
        let tiers: [[AXElementRecord]] = [
            roleFiltered.filter { $0.title?.lowercased() == needle },
            roleFiltered.filter { nonTitleText(of: $0).contains(needle) },
            roleFiltered.filter { $0.title?.lowercased().contains(needle) == true },
            roleFiltered.filter { nonTitleText(of: $0).contains { $0.contains(needle) } },
        ]

        guard let best = tiers.first(where: { !$0.isEmpty }) else { return nil }
        guard best.count == 1, let match = best.first else { return .ambiguous(best) }
        return .found(match)
    }

    static func match(records: [AXElementRecord], query: String, role: String?) -> AXElementRecord? {
        switch resolve(records: records, query: query, role: role) {
        case .found(let record):
            return record
        case .ambiguous, nil:
            return nil
        }
    }

    /// "button" and "AXButton" both match `AXButton`, mirroring the tree walker's
    /// role-filter normalization.
    static func roleMatches(_ recordRole: String, filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        let actual = recordRole.lowercased()
        let wanted = filter.lowercased()
        return actual == wanted || actual == "ax" + wanted
    }

    private static func nonTitleText(of record: AXElementRecord) -> [String] {
        [record.description, record.value]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
    }
}
