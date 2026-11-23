import Foundation

// The inspector JSON field's text and the stored value are two mirrors of one value. They agree at `lastSynced`, so
// a value from the store that still means the same thing is this editor's own write coming back and is ignored.
// Adopting that echo overwrote a keystroke with the value it replaced and pushed it back, forever (#3051).
internal struct JsonFieldEditingModel: Equatable, Sendable {
    private(set) var displayText: String

    // In display form: the stored form went through `JsonReindenter.normalize` and never equals what the editor holds.
    private var lastSynced: String

    internal init(storedValue: String) {
        let opening = JsonReindenter.reindent(storedValue)
        self.displayText = opening
        self.lastSynced = opening
    }

    // Nil when the text already agrees with the store and writing it would only start another round.
    internal mutating func typed(_ text: String) -> String? {
        displayText = text
        guard !Self.isLiterallyEqual(text, lastSynced) else { return nil }
        lastSynced = text
        return text
    }

    // Whether the editor adopted the value. One that normalizes to `lastSynced` is an echo, compacted or dropped by
    // `MultiRowEditState`; anything else is external: Set NULL, Set DEFAULT, Set EMPTY, an SQL function, the value window.
    // `normalize` returns invalid JSON unchanged, so a half-typed value compares exactly.
    internal mutating func received(_ value: String) -> Bool {
        guard !Self.isLiterallyEqual(value, lastSynced),
              JsonReindenter.normalize(value) != JsonReindenter.normalize(lastSynced) else { return false }
        displayText = JsonReindenter.reindent(value)
        lastSynced = displayText
        return true
    }

    // String's == walks a bridged multi-megabyte text through Unicode normalization; the editor's text is bridged.
    private static func isLiterallyEqual(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).isEqual(to: rhs)
    }
}
