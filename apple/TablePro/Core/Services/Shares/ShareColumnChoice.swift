//
//  ShareColumnChoice.swift
//  TablePro
//

import Foundation

// What a share does with one column of the result: send it as it is, mask it, or leave it out.
internal struct ShareColumnChoice: Identifiable, Equatable, Sendable {
    enum Action: String, CaseIterable, Identifiable, Sendable {
        case keep
        case mask
        case remove

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .keep: String(localized: "Keep")
            case .mask: String(localized: "Mask")
            case .remove: String(localized: "Remove")
            }
        }
    }

    // The column's position in the share source.
    let index: Int
    let name: String
    // The connection's rules mask this column for everything leaving the app, so it is never sent as it is.
    let ruleStyle: MaskingStyle?
    // Masked whole only because nothing traced it to a table column, whatever the rules say.
    let isUntraced: Bool
    let detection: SensitiveDetection?
    private(set) var action: Action
    private(set) var style: MaskingStyle

    var id: Int { index }

    init(index: Int, name: String, ruleStyle: MaskingStyle?, detection: SensitiveDetection?, isUntraced: Bool = false) {
        self.index = index
        self.name = name
        self.ruleStyle = ruleStyle
        self.isUntraced = isUntraced
        self.detection = detection
        if let ruleStyle {
            action = .mask
            style = ruleStyle
        } else if let detection {
            action = .mask
            style = detection.style
        } else {
            action = .keep
            style = .full
        }
    }

    var allowsKeep: Bool {
        ruleStyle == nil
    }

    // Under a rule only a style that hides at least as much: the rule's own, Full or NULL.
    var allowedStyles: [MaskingStyle] {
        MaskingStyle.allCases.filter { MaskingStyle.strictest(ruleStyle, $0) == $0 }
    }

    func choosing(_ action: Action) -> ShareColumnChoice? {
        guard action != .keep || allowsKeep else { return nil }
        var choice = self
        choice.action = action
        return choice
    }

    func choosing(style: MaskingStyle) -> ShareColumnChoice? {
        guard allowedStyles.contains(style) else { return nil }
        var choice = self
        choice.style = style
        return choice
    }

    var maskedStyle: MaskingStyle? {
        action == .mask ? style : nil
    }

    // Nil when the column is left out. A rule's own style is already on the values, so it is not applied twice.
    var sharedColumn: ShareSnapshotBuilder.SharedColumn? {
        switch action {
        case .remove: nil
        case .keep: ShareSnapshotBuilder.SharedColumn(source: index, applying: nil, masked: nil)
        case .mask: ShareSnapshotBuilder.SharedColumn(source: index, applying: style == ruleStyle ? nil : style, masked: style)
        }
    }

    // Nil once the caller's task is cancelled.
    static func defaults(for source: ShareResultSource, windows: [Int]) -> [ShareColumnChoice]? {
        guard let detections = SensitiveDataDetector.detections(in: source, windows: windows) else { return nil }
        return source.columns.indices.map { index in
            ShareColumnChoice(
                index: index,
                name: source.columns[index],
                ruleStyle: source.masks.styles[index],
                detection: detections[index],
                isUntraced: source.untracedColumns.contains(index)
            )
        }
    }

    // What the person chose before the rows were read again, matched by column name and held to what each column allows.
    static func carryingOver(_ previous: [ShareColumnChoice], onto defaults: [ShareColumnChoice]) -> [ShareColumnChoice] {
        guard !previous.isEmpty else { return defaults }
        var unmatched = previous
        return defaults.map { choice in
            guard let match = unmatched.firstIndex(where: { $0.name == choice.name }) else { return choice }
            let earlier = unmatched.remove(at: match)
            var carried = choice.choosing(style: earlier.style) ?? choice
            carried = carried.choosing(earlier.action) ?? carried
            return carried
        }
    }

    // Detection reads the first max_rows rows and the rows a keep-everything snapshot sends, as the core does, so neither
    // the body budget nor a short sensitive run hides a column. Nil once the caller's task is cancelled.
    static func prepare(_ source: ShareResultSource, maxRows: Int, keeping previous: [ShareColumnChoice]) -> SharePreparation? {
        let rowCap = max(0, maxRows)
        guard let everything = ShareSnapshotBuilder.build(source, maxRows: rowCap) else { return nil }
        let sentWhole = if case .snapshot(let snapshot) = everything { snapshot.rows.count } else { 0 }
        guard let defaults = defaults(for: source, windows: [rowCap, sentWhole]) else { return nil }
        let columns = carryingOver(previous, onto: defaults)
        guard let built = ShareSnapshotBuilder.build(source, maxRows: rowCap, columns: columns.compactMap(\.sharedColumn))
        else { return nil }
        return SharePreparation(columns: columns, rowCap: rowCap, snapshot: built)
    }
}

// What a share sheet starts from once the rows are read.
internal struct SharePreparation: Sendable {
    let columns: [ShareColumnChoice]
    // The rows the detectors read, which the snapshot never goes past.
    let rowCap: Int
    let snapshot: ShareSnapshotOutcome
}
