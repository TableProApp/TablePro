//
//  SQLFormatterSettings.swift
//  TablePro
//

import Foundation
import TableProAutocomplete

// The defaults reproduce the formatter's output from before it had settings.
struct SQLFormatterSettings: Codable, Equatable {
    var rules: SQLFormatterOptions
    var indentFollowsTabWidth: Bool
    var keywordCaseFollowsEditor: Bool

    static let `default` = SQLFormatterSettings()

    init(
        rules: SQLFormatterOptions = .default,
        indentFollowsTabWidth: Bool = false,
        keywordCaseFollowsEditor: Bool = true
    ) {
        self.rules = rules
        self.indentFollowsTabWidth = indentFollowsTabWidth
        self.keywordCaseFollowsEditor = keywordCaseFollowsEditor
    }

    // An imported file names every rule, so nothing follows this Mac's other settings afterwards.
    init(imported rules: SQLFormatterOptions) {
        self.init(rules: rules, indentFollowsTabWidth: false, keywordCaseFollowsEditor: false)
    }

    func options(for editor: EditorSettings) -> SQLFormatterOptions {
        resolved(tabWidth: editor.clampedTabWidth, editorKeywordCase: editor.keywordCase)
    }

    func resolved(tabWidth: Int, editorKeywordCase: SQLKeywordCase) -> SQLFormatterOptions {
        var options = rules
        if indentFollowsTabWidth {
            options.indentWidth = min(max(tabWidth, SQLFormatterOptions.indentWidthRange.lowerBound),
                                      SQLFormatterOptions.indentWidthRange.upperBound)
        }
        if keywordCaseFollowsEditor {
            options.keywordCase = editorKeywordCase.prefersUppercase ? .upper : .lower
        }
        return options
    }

    private enum FollowKeys: String, CodingKey {
        case indentFollowsTabWidth
        case keywordCaseFollowsEditor
    }

    // Lenient, like every synced settings blob: a value this build cannot read costs only that field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SQLFormatterOptions.CodingKeys.self)
        let follow = try decoder.container(keyedBy: FollowKeys.self)
        let fallback = SQLFormatterOptions.default
        var rules = SQLFormatterOptions()
        rules.indentStyle = container.decodeSetting(.indentStyle, default: fallback.indentStyle)
        rules.indentWidth = Self.inRange(
            container.decodeSetting(.indentWidth, default: fallback.indentWidth),
            SQLFormatterOptions.indentWidthRange,
            otherwise: fallback.indentWidth
        )
        rules.keywordCase = container.decodeSetting(.keywordCase, default: fallback.keywordCase)
        rules.functionCase = container.decodeSetting(.functionCase, default: fallback.functionCase)
        rules.commaPosition = container.decodeSetting(.commaPosition, default: fallback.commaPosition)
        rules.lineWidth = Self.inRange(
            container.decodeSetting(.lineWidth, default: fallback.lineWidth),
            SQLFormatterOptions.lineWidthRange,
            otherwise: fallback.lineWidth
        )
        rules.joinCondition = container.decodeSetting(.joinCondition, default: fallback.joinCondition)
        rules.alignAliases = container.decodeSetting(.alignAliases, default: fallback.alignAliases)
        self.rules = rules
        let defaults = Self.default
        indentFollowsTabWidth = follow.decodeSetting(.indentFollowsTabWidth, default: defaults.indentFollowsTabWidth)
        keywordCaseFollowsEditor = follow.decodeSetting(
            .keywordCaseFollowsEditor, default: defaults.keywordCaseFollowsEditor
        )
    }

    func encode(to encoder: Encoder) throws {
        try rules.encode(to: encoder)
        var follow = encoder.container(keyedBy: FollowKeys.self)
        try follow.encode(indentFollowsTabWidth, forKey: .indentFollowsTabWidth)
        try follow.encode(keywordCaseFollowsEditor, forKey: .keywordCaseFollowsEditor)
    }

    private static func inRange(_ value: Int, _ range: ClosedRange<Int>, otherwise fallback: Int) -> Int {
        range.contains(value) ? value : fallback
    }
}
