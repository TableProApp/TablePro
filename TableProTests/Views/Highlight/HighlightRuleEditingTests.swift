//
//  HighlightRuleEditingTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct HighlightRuleEditingTests {
    private func rule(
        columnName: String = "Added",
        occurrence: Int = 0,
        filterOperator: FilterOperator = .equal,
        value: String = "",
        isCaseSensitive: Bool? = nil
    ) -> HighlightRule {
        HighlightRule(
            columnName: columnName,
            columnOccurrence: occurrence,
            filterOperator: filterOperator,
            value: value,
            isCaseSensitive: isCaseSensitive
        )
    }

    /// The shape `HighlightRulesPopover.binding(for:)` vends: a whole-rule binding backed by the
    /// list it edits. `writes` counts the round trips a single user action costs.
    private final class RuleList {
        private(set) var rules: [HighlightRule]
        private(set) var writes = 0

        init(_ rules: [HighlightRule]) {
            self.rules = rules
        }

        func binding(for id: UUID) -> Binding<HighlightRule> {
            Binding(
                get: { [self] in rules.first { $0.id == id } ?? rules[0] },
                set: { [self] updated in
                    guard let index = rules.firstIndex(where: { $0.id == updated.id }) else { return }
                    rules[index] = updated
                    writes += 1
                }
            )
        }
    }

    @Test("Selecting a column keeps both halves of the column identity")
    func selectingAColumnKeepsNameAndOccurrence() {
        let updated = rule(columnName: "Added", occurrence: 0).selectingColumn(named: "Artist", occurrence: 2)

        #expect(updated.columnName == "Artist")
        #expect(updated.columnOccurrence == 2)
    }

    @Test("A column occurrence below zero is clamped, as the initializer clamps it")
    func negativeOccurrenceIsClamped() {
        #expect(rule().selectingColumn(named: "Artist", occurrence: -3).columnOccurrence == 0)
    }

    @Test("Selecting an operator carries its case default with it")
    func selectingAnOperatorSetsItsCaseDefault() {
        let updated = rule(filterOperator: .equal).selectingOperator(.contains)

        #expect(updated.filterOperator == .contains)
        #expect(updated.isCaseSensitive == false)
        #expect(updated.selectingOperator(.equal).isCaseSensitive == true)
    }

    @Test("Reselecting the operator already in force leaves a hand-set Match Case alone")
    func reselectingTheSameOperatorIsANoOp() {
        let manual = rule(filterOperator: .contains, isCaseSensitive: true)

        #expect(manual.selectingOperator(.contains) == manual)
    }

    /// The defect behind #3015: two field writes through one binding are two get-modify-set round
    /// trips, and the second resolves against the value before the first.
    @Test("Changing the column through the rule binding costs one write and does not revert")
    func changingTheColumnDoesNotRevert() {
        let list = RuleList([rule(columnName: "Added", occurrence: 0)])
        let binding = list.binding(for: list.rules[0].id)

        binding.wrappedValue = binding.wrappedValue.selectingColumn(named: "Artist", occurrence: 1)

        #expect(list.rules[0].columnName == "Artist")
        #expect(list.rules[0].columnOccurrence == 1)
        #expect(list.writes == 1)
    }

    @Test("Changing the operator through the rule binding costs one write and does not revert")
    func changingTheOperatorDoesNotRevert() {
        let list = RuleList([rule(filterOperator: .equal)])
        let binding = list.binding(for: list.rules[0].id)

        binding.wrappedValue = binding.wrappedValue.selectingOperator(.between)

        #expect(list.rules[0].filterOperator == .between)
        #expect(list.writes == 1)
    }

    @Test("Two field writes in one turn lose the first, which is why an edit is one write")
    func twoFieldWritesInOneTurnLoseTheFirst() {
        let list = RuleList([rule(columnName: "Added", occurrence: 0)])
        let binding = list.binding(for: list.rules[0].id)

        binding.columnName.wrappedValue = "Artist"
        binding.columnOccurrence.wrappedValue = 0

        #expect(list.rules[0].columnName == "Artist")
        #expect(list.writes == 2)
    }

    @Test("Every single-property control still writes through untouched")
    func singlePropertyEditsAreUnaffected() {
        let list = RuleList([rule()])
        let binding = list.binding(for: list.rules[0].id)

        binding.color.wrappedValue = .blue
        binding.target.wrappedValue = .cell
        binding.isEnabled.wrappedValue = false
        binding.value.wrappedValue = "paid"

        #expect(list.rules[0].color == .blue)
        #expect(list.rules[0].target == .cell)
        #expect(list.rules[0].isEnabled == false)
        #expect(list.rules[0].value == "paid")
    }

    @Test("A rule on a column this result does not carry is called out")
    func missingColumnWarns() {
        let warning = HighlightRuleWarning.warning(for: rule(columnName: "Gone"), isColumnPresent: false)

        #expect(warning == .columnMissing("Gone"))
    }

    @Test("A pattern that will not compile is called out rather than silently matching nothing")
    func unusablePatternWarns() {
        let broken = rule(filterOperator: .regex, value: "^(Live")

        #expect(HighlightRuleWarning.warning(for: broken, isColumnPresent: true) == .unusablePattern)
        #expect(HighlightCondition.isUsableRegexPattern("^(Live") == false)
    }

    @Test("A pattern that compiles, an empty one, and a non-regex operator raise nothing")
    func usablePatternsDoNotWarn() {
        #expect(HighlightRuleWarning.warning(for: rule(filterOperator: .regex, value: "^Live"), isColumnPresent: true) == nil)
        #expect(HighlightRuleWarning.warning(for: rule(filterOperator: .regex), isColumnPresent: true) == nil)
        #expect(HighlightRuleWarning.warning(for: rule(value: "^(Live"), isColumnPresent: true) == nil)
    }

    @Test("A long but valid pattern is usable, because the limit caps the text and not the pattern")
    func aLongValidPatternIsUsable() {
        let long = (0..<4_000).map { "a\($0 % 10)b" }.joined(separator: "|")

        #expect((long as NSString).length > HighlightCondition.searchLimit)
        #expect(HighlightCondition.isUsableRegexPattern(long))
        #expect(!rule(filterOperator: .regex, value: long).hasUnusablePattern)
    }

    @Test("A long pattern that will not compile is still reported as unusable")
    func aLongMalformedPatternIsUnusable() {
        let long = String(repeating: "a", count: HighlightCondition.searchLimit + 1) + "("

        #expect(!HighlightCondition.isUsableRegexPattern(long))
    }

    @Test("A rule whose pattern will not compile is not counted among the active rules")
    func unusablePatternIsNotCountedAsActive() {
        let broken = rule(filterOperator: .regex, value: "^(Live")
        let working = rule(filterOperator: .regex, value: "^Live")
        let state = StatusBarHighlightState(
            rules: [broken, working],
            columns: ["Added"],
            isPersisted: true,
            presentationRequest: 0,
            onChange: { _ in },
            onDismiss: { _ in }
        )

        #expect(broken.hasUnusablePattern)
        #expect(!working.hasUnusablePattern)
        #expect(state.activeRuleCount == 1)
    }

    @Test("A rule that cannot compile is still kept, because a half-typed pattern is not a rule to delete")
    func unusablePatternStaysValid() {
        #expect(rule(filterOperator: .regex, value: "^(Live").isValid)
    }

    @Test("A missing column outranks a broken pattern, because it decides the rule on its own")
    func missingColumnOutranksTheBrokenPattern() {
        let broken = rule(filterOperator: .regex, value: "^(Live")

        #expect(HighlightRuleWarning.warning(for: broken, isColumnPresent: false) == .columnMissing("Added"))
    }
}
