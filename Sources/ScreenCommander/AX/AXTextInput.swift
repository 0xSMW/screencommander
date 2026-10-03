import ApplicationServices
import Foundation

/// Text input through the accessibility tree, the first tier of `type`.
///
/// Typing inserts at the element's caret and replaces its selection, the same as
/// key events would. `AXSelectedText` does that in one write. Chromium accepts that
/// write and ignores it, so when the value reads back unchanged the insert is
/// spliced into `AXValue` instead and the caret is put after the inserted text.
/// Replacing the whole value is a separate, explicit operation.
///
/// The clipboard is never touched. A secure text field is written but never read.
enum AXTextInput {
    /// The element did not take the text through accessibility, and nothing about it
    /// changed, so the caller may fall through to key events without typing twice.
    struct Refused: Error, Equatable {
        var reason: String
    }

    /// How a read-back after a write came out.
    enum ReadBack: Equatable {
        /// The value equals what the write should have produced.
        case matched
        /// The value changed, but not to what was expected (a formatter, a filter,
        /// or another writer). Typing again would duplicate text.
        case changed
        /// The value never moved from what it was before the write.
        case unchanged
    }

    /// Reads after a write before giving up on it. Chromium applies accessibility
    /// writes asynchronously, a few tens of milliseconds later.
    static let readBackAttempts = 6

    /// Inserts `text` at the caret (`replace` false) or replaces the whole value.
    /// Returns what the read-back verified. Throws `Refused` when the element did not
    /// take the text and is unchanged.
    static func write(
        _ text: String,
        replace: Bool,
        into element: AXElement,
        actions: AXActionPerforming,
        pause: () -> Void
    ) throws -> ActionVerification {
        if replace {
            return try replaceValue(with: text, in: element, actions: actions, pause: pause)
        }
        return try insert(text, into: element, actions: actions, pause: pause)
    }

    static func insert(
        _ text: String,
        into element: AXElement,
        actions: AXActionPerforming,
        pause: () -> Void
    ) throws -> ActionVerification {
        guard !text.isEmpty else {
            return .checked(true)
        }
        let secure = actions.isSecureText(element)
        let before = secure ? nil : actions.readValue(of: element)
        let selection = actions.readSelectedTextRange(of: element)
        let expected = before.map { splice(text, into: $0, at: selection) }

        if actions.isSettable(kAXSelectedTextAttribute, on: element) {
            // An AX timeout can follow a write that the app already applied.
            // Even a throwing write needs read-back before another delivery.
            do {
                try actions.setSelectedText(text, on: element)
            } catch {
                // Read-back below decides whether retrying is safe. Without a
                // readable baseline, completion stays unknown and stops here.
            }
            if secure {
                return .unknown
            }
            guard let before, let expected else {
                // Nothing to compare against: the write was accepted, unconfirmed.
                return .unknown
            }
            switch readBack(element, actions: actions, expected: expected, before: before, pause: pause) {
            case .matched:
                return .checked(true)
            case .changed:
                return .checked(false)
            case .unchanged:
                break
            }
        }

        // Splice the insert into the value: Chromium's text controls take this.
        guard !secure, let before, let expected, actions.isSettable(kAXValueAttribute, on: element) else {
            throw Refused(reason: secure
                ? "The secure text field does not accept AXSelectedText."
                : "The element accepts neither AXSelectedText nor a readable, settable AXValue.")
        }
        do {
            try actions.setValue(expected, on: element)
        } catch {
            // The app may have applied the value before reporting failure.
            // Only an unchanged read-back permits keyboard fallback.
        }
        let caret = (selection?.location).map { min($0, before.utf16.count) } ?? before.utf16.count
        try? actions.setSelectedTextRange(AXTextRange(location: caret + text.utf16.count, length: 0), on: element)
        switch readBack(element, actions: actions, expected: expected, before: before, pause: pause) {
        case .matched:
            return .checked(true)
        case .changed:
            return .checked(false)
        case .unchanged:
            // The caret was moved for an insert that never happened. Put the caret
            // and selection back, so key events that follow type where they would have.
            if let selection {
                try? actions.setSelectedTextRange(selection, on: element)
            }
            throw Refused(reason: "The element accepted the accessibility writes but its value did not change.")
        }
    }

    static func replaceValue(
        with text: String,
        in element: AXElement,
        actions: AXActionPerforming,
        pause: () -> Void
    ) throws -> ActionVerification {
        let secure = actions.isSecureText(element)
        guard actions.isSettable(kAXValueAttribute, on: element) else {
            throw Refused(reason: "The element's AXValue is not settable.")
        }
        let before = secure ? nil : actions.readValue(of: element)
        do {
            try actions.setValue(text, on: element)
        } catch {
            // A throwing write may have completed. Unreadable and secure
            // values remain unverified rather than being typed a second time.
        }
        guard !secure, let before else {
            return .unknown
        }
        switch readBack(element, actions: actions, expected: text, before: before, pause: pause) {
        case .matched:
            return .checked(true)
        case .changed:
            return .checked(false)
        case .unchanged:
            throw Refused(reason: "The element accepted the AXValue write but its value did not change.")
        }
    }

    /// `value` with `text` in place of `selection`, in the UTF-16 offsets AX uses.
    /// With no selection reported, the text goes at the end.
    static func splice(_ text: String, into value: String, at selection: AXTextRange?) -> String {
        let units = Array(value.utf16)
        let location = min(max(selection?.location ?? units.count, 0), units.count)
        let length = min(max(selection?.length ?? 0, 0), units.count - location)
        let result = units[..<location] + Array(text.utf16) + units[(location + length)...]
        return String(decoding: result, as: UTF16.self)
    }

    /// Reads the value until it equals `expected`, up to `readBackAttempts` times.
    static func readBack(
        _ element: AXElement,
        actions: AXActionPerforming,
        expected: String,
        before: String,
        pause: () -> Void
    ) -> ReadBack {
        var last: String?
        for attempt in 0..<readBackAttempts {
            last = actions.readValue(of: element)
            if last == expected {
                return .matched
            }
            if attempt < readBackAttempts - 1 {
                pause()
            }
        }
        // A value that stopped being readable counts as changed, so nothing is typed twice.
        return last == before ? .unchanged : .changed
    }
}
