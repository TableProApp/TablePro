import Foundation

struct SnippetSession: Equatable {
    struct Field: Equatable {
        var ranges: [NSRange]
        let choices: [String]
    }

    private(set) var fields: [Field]
    private(set) var finalRange: NSRange
    private(set) var span: NSRange
    private(set) var current: Int
    // The active field was typed away: `current` names the field that followed it, which the next Tab selects.
    private var currentIsGone = false

    init?(snippet: EditorSnippet, at location: Int) {
        let length = (snippet.text as NSString).length
        let shift = { (range: NSRange) in NSRange(location: range.location + location, length: range.length) }
        let fields = snippet.fields
            .map { Field(ranges: $0.ranges.map(shift).sorted { $0.location < $1.location }, choices: $0.choices) }
            .filter { !$0.ranges.isEmpty }
        guard !fields.isEmpty else { return nil }

        self.fields = fields
        self.finalRange = shift(snippet.finalRange ?? NSRange(location: length, length: 0))
        self.span = NSRange(location: location, length: length)
        self.current = 0
    }

    var currentField: Field? {
        !currentIsGone && fields.indices.contains(current) ? fields[current] : nil
    }

    // False once Tab has passed the last field: the final stop ends the session.
    mutating func advance() -> Bool {
        let next = currentIsGone ? current : current + 1
        guard next < fields.count else { return false }
        current = next
        currentIsGone = false
        return true
    }

    mutating func retreat() {
        current = max(current - 1, 0)
        currentIsGone = false
    }

    func contains(_ selection: NSRange) -> Bool {
        selection.location >= span.location && NSMaxRange(selection) <= NSMaxRange(span)
    }

    // False when the edit leaves nothing sound to track: it replaced the whole snippet, as undoing the expansion
    // does, crossed a field edge, or took every field. Typing over a field that is the whole snippet keeps it.
    mutating func apply(edit range: NSRange, replacementLength: Int, isUndo: Bool = false) -> Bool {
        let activeRanges = currentField?.ranges ?? []
        if range.length > 0, range.location <= span.location, NSMaxRange(range) >= NSMaxRange(span),
           isUndo || !activeRanges.contains(range) {
            return false
        }
        guard case .range(let newSpan) = Self.adjust(
            span,
            edit: range,
            length: replacementLength,
            growsAtEdges: true,
            growsAtStart: true
        ) else { return false }

        var kept: [Field] = []
        var newCurrent = current
        var newCurrentIsGone = currentIsGone
        for (index, field) in fields.enumerated() {
            let isActive = index == current && !currentIsGone
            var ranges: [NSRange] = []
            for fieldRange in field.ranges {
                let growsAtEdges = isActive || Self.encloses(fieldRange, anyOf: activeRanges, touching: range.location)
                // Typing at the end of one copy that touches the next belongs to the first: the second shifts.
                let followsCopy = activeRanges.contains { $0 != fieldRange && NSMaxRange($0) == fieldRange.location }
                switch Self.adjust(
                    fieldRange,
                    edit: range,
                    length: replacementLength,
                    growsAtEdges: growsAtEdges,
                    growsAtStart: !followsCopy
                ) {
                case .range(let adjusted):
                    ranges.append(adjusted)
                case .swallowed:
                    continue
                case .crossed:
                    return false
                }
            }
            if ranges.isEmpty {
                if index < current { newCurrent -= 1 }
                if isActive { newCurrentIsGone = true }
                continue
            }
            kept.append(Field(ranges: ranges, choices: field.choices))
        }
        guard !kept.isEmpty else { return false }

        switch Self.adjust(finalRange, edit: range, length: replacementLength, growsAtEdges: false, growsAtStart: false) {
        case .range(let adjusted):
            finalRange = adjusted
        case .swallowed, .crossed:
            finalRange = NSRange(location: range.location + replacementLength, length: 0)
        }
        fields = kept
        current = newCurrent
        currentIsGone = newCurrentIsGone
        span = newSpan
        return true
    }

    // A field holding the active one grows with it, so text typed at their shared edge stays inside both. An empty
    // field holds nothing: two empty fields at one spot are neighbours.
    private static func encloses(_ outer: NSRange, anyOf active: [NSRange], touching point: Int) -> Bool {
        outer.length > 0 && active.contains { inner in
            inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
                && inner.location <= point && point <= NSMaxRange(inner)
        }
    }

    private enum Adjusted: Equatable {
        case range(NSRange)
        case swallowed
        case crossed
    }

    // Typing at an edge grows only the active field, so text typed after an empty field never joins the next one.
    private static func adjust(
        _ tracked: NSRange,
        edit: NSRange,
        length: Int,
        growsAtEdges: Bool,
        growsAtStart: Bool
    ) -> Adjusted {
        let delta = length - edit.length
        let start = tracked.location
        let end = NSMaxRange(tracked)

        if edit.length == 0 {
            let point = edit.location
            if point < start { return .range(NSRange(location: start + delta, length: tracked.length)) }
            if point > end { return .range(tracked) }
            let growsHere = point == start ? growsAtEdges && growsAtStart : growsAtEdges
            if (point > start && point < end) || growsHere {
                return .range(NSRange(location: start, length: tracked.length + length))
            }
            return point == start ? .range(NSRange(location: start + length, length: tracked.length)) : .range(tracked)
        }

        if NSMaxRange(edit) <= start { return .range(NSRange(location: start + delta, length: tracked.length)) }
        if edit.location >= end { return .range(tracked) }
        if edit.location >= start && NSMaxRange(edit) <= end {
            return .range(NSRange(location: start, length: tracked.length + delta))
        }
        if edit.location <= start && NSMaxRange(edit) >= end { return .swallowed }
        return .crossed
    }
}
