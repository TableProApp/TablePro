import Foundation
import SwiftUI
@testable import TablePro
import Testing

struct QueryResultLimitTests {
    @Test("No limit turns the limit off and keeps the stored cap")
    func noLimitKeepsCap() {
        let settings = DataGridSettings(queryResultRowCap: 5_000, truncateQueryResults: true)
        let updated = settings.withQueryResultLimit(nil)
        #expect(updated.truncateQueryResults == false)
        #expect(updated.queryResultRowCap == 5_000)
        #expect(updated.queryResultLimit == nil)
    }

    @Test("Picking a limit turns it on and sets the cap together")
    func pickSetsBoth() {
        let settings = DataGridSettings(queryResultRowCap: 5_000, truncateQueryResults: false)
        let updated = settings.withQueryResultLimit(50_000)
        #expect(updated.truncateQueryResults)
        #expect(updated.queryResultRowCap == 50_000)
        #expect(updated.queryResultLimit == 50_000)
    }

    @Test("A stored cap of 0 reads as No limit")
    func zeroCapReadsNoLimit() {
        #expect(DataGridSettings(queryResultRowCap: 0, truncateQueryResults: true).queryResultLimit == nil)
    }

    @Test("A cap out of range reads as the cap queries run with")
    func outOfRangeCapReadsClamped() {
        #expect(DataGridSettings(queryResultRowCap: 50, truncateQueryResults: true).queryResultLimit == 100)
        #expect(DataGridSettings(queryResultRowCap: 9_000_000, truncateQueryResults: true).queryResultLimit == 500_000)
    }

    @Test("The pop-up writes the limit and the switch in one commit")
    @MainActor
    func bindingWritesOnce() {
        let slice = SettingsSlice(DataGridSettings(queryResultRowCap: 5_000, truncateQueryResults: false))
        let commits = CommitLog<DataGridSettings>()
        slice.attach { _, new in commits.values.append(new) }
        let binding = DataGridSection.queryResultLimitBinding(sliceBinding(slice))

        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = 100_000

        #expect(commits.values.count == 1)
        #expect(commits.values.first?.truncateQueryResults == true)
        #expect(commits.values.first?.queryResultRowCap == 100_000)
        #expect(binding.wrappedValue == 100_000)

        binding.wrappedValue = nil

        #expect(commits.values.count == 2)
        #expect(slice.value.truncateQueryResults == false)
        #expect(slice.value.queryResultRowCap == 100_000)
    }
}

struct NullDisplayTests {
    // Drives a draft the way SettingsTextField does: a write only on commit, then a read-back.
    private struct FieldHarness {
        var stored: String
        var draft: SettingsTextDraft
        var writes: [String] = []

        init(stored: String) {
            self.stored = stored
            draft = SettingsTextDraft(stored)
        }

        var error: String? { DataGridSettings.nullDisplayValidationError(for: draft.text) }

        mutating func type(_ text: String) {
            draft.text = text
        }

        mutating func commit() {
            let resolved = draft.commit(to: stored) { candidate in
                DataGridSettings.nullDisplayValidationError(for: candidate) == nil
                    ? .accept(DataGridSettings.normalizedNullDisplay(candidate))
                    : .revert
            }
            if let resolved {
                stored = resolved
                writes.append(resolved)
            }
            draft.settle(to: stored)
        }

        mutating func remoteChange(_ value: String) {
            stored = value
            draft.resync(to: value)
        }
    }

    @Test("A blank entry commits as NULL and the field reads it back")
    func blankCommitsNull() {
        var field = FieldHarness(stored: "(null)")
        field.type("   ")
        #expect(field.error == nil)
        field.commit()
        #expect(field.stored == "NULL")
        #expect(field.draft.text == "NULL")
    }

    @Test("A trailing space typed mid-word is not an error and is trimmed on commit")
    func trailingSpaceIsNotAnError() {
        var field = FieldHarness(stored: "NULL")
        field.type("n/a ")
        #expect(field.error == nil)
        field.type(String(repeating: "x", count: 20) + " ")
        #expect(field.error == nil)
        field.type("n/a ")
        field.commit()
        #expect(field.stored == "n/a")
        #expect(field.writes == ["n/a"])
    }

    @Test("More than 20 characters shows the error and a commit restores the saved value")
    func overLimitReverts() {
        var field = FieldHarness(stored: "NULL")
        field.type(String(repeating: "x", count: 21))
        #expect(field.error != nil)
        field.commit()
        #expect(field.stored == "NULL")
        #expect(field.writes.isEmpty)
        #expect(field.draft.text == "NULL")
    }

    @Test("An untouched field follows a remote change, an edited one keeps the edit")
    func untouchedFollowsRemote() {
        var field = FieldHarness(stored: "NULL")
        field.remoteChange("<null>")
        #expect(field.draft.text == "<null>")

        field.type("nil")
        field.remoteChange("(none)")
        #expect(field.draft.text == "nil")
        field.commit()
        #expect(field.stored == "nil")
    }

    @Test("An unchanged commit writes nothing")
    func unchangedCommitWritesNothing() {
        var field = FieldHarness(stored: "NULL")
        field.type("NULL ")
        field.commit()
        #expect(field.writes.isEmpty)
    }

    @Test("The stored value is cleaned, cut to 20 characters, then trimmed again")
    func sanitizeAfterPrefix() {
        #expect(DataGridSettings.normalizedNullDisplay("abcdefghijklmnopqrs tuvwxyz") == "abcdefghijklmnopqrs")
        #expect(DataGridSettings.normalizedNullDisplay(" a\tb\n") == "a b")
        #expect(DataGridSettings.normalizedNullDisplay("\n\t ") == "NULL")
        #expect(DataGridSettings(nullDisplay: String(repeating: "y", count: 30)).validatedNullDisplay.count == 20)
    }
}

@MainActor
struct DataPaneChoiceTests {
    @Test("A page size off the list is offered after the list")
    func pageSizeExtra() {
        let options = SettingsChoices.options(DataGridSection.pageSizes, including: 250)
        #expect(options.fixed == DataGridSection.pageSizes)
        #expect(options.extra == 250)
        #expect(SettingsChoices.options(DataGridSection.pageSizes, including: 1_000).extra == nil)
    }

    @Test("Always is on the exact row count list, another threshold is offered after it")
    func exactCountExtra() {
        #expect(SettingsChoices.options(DataGridSection.exactCountThresholds, including: Int.max).extra == nil)
        #expect(SettingsChoices.options(DataGridSection.exactCountThresholds, including: 50_000).extra == 50_000)
    }

    @Test("No limit adds no extra result limit, an off-list cap does")
    func resultLimitExtra() {
        let limits = DataGridSection.queryResultLimits.map { Optional($0) }
        let first = DataGridSection.queryResultLimits.first
        let noLimit = DataGridSettings(truncateQueryResults: false).queryResultLimit
        #expect(SettingsChoices.options(limits, including: noLimit ?? first).extra == nil)
        let offList = DataGridSettings(queryResultRowCap: 2_500, truncateQueryResults: true).queryResultLimit
        #expect(SettingsChoices.options(limits, including: offList ?? first).extra == .some(2_500))
    }

    @Test("History limits keep No limit and Forever on the list")
    func historyChoices() {
        #expect(SettingsChoices.options(QueryHistorySettingsPage.maxEntries, including: 0).extra == nil)
        #expect(SettingsChoices.options(QueryHistorySettingsPage.maxEntries, including: 2_000).extra == 2_000)
        #expect(SettingsChoices.options(QueryHistorySettingsPage.retentionDays, including: 0).extra == nil)
        #expect(SettingsChoices.options(QueryHistorySettingsPage.retentionDays, including: 14).extra == 14)
    }

    @Test("Row counts are grouped the way the locale groups them")
    func rowTitlesGroupDigits() {
        #expect(DataGridSection.rowsTitle(10_000).contains(SettingsFormat.count(10_000)))
        #expect(DataGridSection.exactCountTitle(100_000).contains(SettingsFormat.count(100_000)))
        #expect(DataGridSection.exactCountTitle(Int.max) == String(localized: "Always"))
    }
}

@MainActor
struct DataRewindSwitchTests {
    @Test("Without a license the switch reads off and the saved choice stays")
    func unlicensedReadsOff() {
        let slice = SettingsSlice(HistorySettings(keepRewindHistory: true))
        let binding = DataRewindPage.keepBinding(sliceBinding(slice), isAvailable: false)
        #expect(binding.wrappedValue == false)
        #expect(slice.value.keepRewindHistory)
        #expect(DataRewindPage.isOn(slice.value, isAvailable: false) == false)
    }

    @Test("With a license the switch shows and writes the saved choice")
    func licensedWrites() {
        let slice = SettingsSlice(HistorySettings(keepRewindHistory: true))
        let binding = DataRewindPage.keepBinding(sliceBinding(slice), isAvailable: true)
        #expect(binding.wrappedValue)
        binding.wrappedValue = false
        #expect(slice.value.keepRewindHistory == false)
        #expect(DataRewindPage.isOn(slice.value, isAvailable: true) == false)
    }
}

@MainActor
struct SettingsClearingTests {
    @Test("Every step runs in order even after one fails, and the failure is reported")
    func runsEveryStep() async {
        let log = CommitLog<String>()
        let cleared = await SettingsClearing.run([
            { log.values.append("history"); return true },
            { log.values.append("rewind"); return false },
            { log.values.append("versions"); return true },
        ])
        #expect(cleared == false)
        #expect(log.values == ["history", "rewind", "versions"])
    }

    @Test("All steps succeeding reports success")
    func allSucceed() async {
        let cleared = await SettingsClearing.run([{ true }, { true }])
        #expect(cleared)
    }
}

@MainActor
private final class CommitLog<Value> {
    var values: [Value] = []
}

// The binding a pane gets from $slice.value.
@MainActor
private func sliceBinding<Value>(_ slice: SettingsSlice<Value>) -> Binding<Value> {
    ObservedObject(wrappedValue: slice).projectedValue.value
}
