import CoreGraphics
import Foundation

/// One node of an accessibility tree, flattened for JSON output.
///
/// `id` is the dot-joined child-index path from the app element (e.g. `"0.3.2"` =
/// app → child 0 → child 3 → child 2). Ids are positional: they stay valid only as
/// long as the UI does not change, so consumers should re-read the tree rather than
/// cache ids across actions.
struct AXElementRecord: Codable, Sendable, Equatable {
    var id: String
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    /// Present (true) only when `value` was cut at the requested max value length.
    var valueTruncated: Bool?
    var description: String?
    var enabled: Bool
    var focused: Bool?
    var actions: [String]
    /// Frame in global top-left-origin points, when the app reports one.
    var boundsPoints: RectD?
    /// Frame in the pixel space of the reference screenshot metadata, when the
    /// element lies within that screenshot's bounds.
    var boundsPixels: RectD?

    init(
        id: String,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        valueTruncated: Bool? = nil,
        description: String? = nil,
        enabled: Bool = true,
        focused: Bool? = nil,
        actions: [String] = [],
        boundsPoints: RectD? = nil,
        boundsPixels: RectD? = nil
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.valueTruncated = valueTruncated
        self.description = description
        self.enabled = enabled
        self.focused = focused
        self.actions = actions
        self.boundsPoints = boundsPoints
        self.boundsPixels = boundsPixels
    }

    /// Depth in the tree, derived from the id path ("0" = 0, "0.3.2" = 2).
    var depth: Int {
        guard !id.isEmpty else { return 0 }
        return id.reduce(0) { $1 == "." ? $0 + 1 : $0 }
    }

    /// Truncates `value` to `maxLength` characters. Returns the (possibly shortened)
    /// value and whether truncation happened.
    static func truncatedValue(_ value: String, maxLength: Int) -> (value: String, truncated: Bool) {
        guard maxLength >= 0, value.count > maxLength else {
            return (value, false)
        }
        return (String(value.prefix(maxLength)), true)
    }
}

/// Renders records as an indented, text-only view of the UI (`--text` mode):
/// one `role "title": value` line per record that carries any text content.
enum AXTextRenderer {
    static func render(_ records: [AXElementRecord]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        for record in records {
            guard let line = renderLine(record) else { continue }
            lines.append(String(repeating: "  ", count: record.depth) + line)
        }
        return lines.joined(separator: "\n")
    }

    /// A single `role "title": value` line, or `nil` when the record has no text
    /// content (no title, value, or description).
    static func renderLine(_ record: AXElementRecord) -> String? {
        let label = firstNonEmpty(record.title, record.description)
        let value = normalized(record.value)
        guard label != nil || value != nil else {
            return nil
        }

        var line = record.role
        if let label {
            line += " \"\(label)\""
        }
        if let value {
            line += ": \(value)"
        }
        return line
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let normalized = normalized(candidate) {
                return normalized
            }
        }
        return nil
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

/// Inverse of `CoordinateMapper`: maps a global-point frame back into the pixel
/// space of a reference screenshot (`px = (globalPoint − metadataBounds.origin) × scale`).
enum AXBoundsMapper {
    /// Returns pixel bounds only when the frame lies entirely within the metadata's
    /// reference bounds; otherwise `nil` (never throws — missing pixels are not an error).
    ///
    /// Mirrors the forward `CoordinateMapper` rule: window-scoped screenshots map
    /// against `windowBoundsPoints`, display-scoped ones against `displayBoundsPoints`.
    static func boundsPixels(for boundsPoints: RectD, metadata: ScreenshotMetadata) -> RectD? {
        let scale = metadata.pointPixelScale
        guard scale > 0 else {
            return nil
        }

        let referenceBounds = metadata.windowBoundsPoints ?? metadata.displayBoundsPoints
        let frame = boundsPoints.cgRect
        guard !frame.isNull, referenceBounds.cgRect.contains(frame) else {
            return nil
        }

        return RectD(
            x: (boundsPoints.x - referenceBounds.x) * scale,
            y: (boundsPoints.y - referenceBounds.y) * scale,
            w: boundsPoints.w * scale,
            h: boundsPoints.h * scale
        )
    }
}
