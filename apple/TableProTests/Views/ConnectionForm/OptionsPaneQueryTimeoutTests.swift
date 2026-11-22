import Foundation
@testable import TablePro
import Testing

struct OptionsPaneQueryTimeoutTests {
    private let english = Locale(identifier: "en_US")

    @Test("No global limit reads as no limit, never as zero")
    func zeroReadsAsNoLimit() {
        #expect(OptionsPaneView.queryTimeoutPlaceholder(globalSeconds: 0) == "No limit")
        #expect(
            OptionsPaneView.queryTimeoutInheritance(globalSeconds: 0, locale: english)
                == "Leave blank to use Settings > Connections: no limit."
        )
    }

    @Test("A global limit reads as a duration in words", arguments: [
        (1, "1 second"),
        (60, "1 minute"),
        (90, "1 minute, 30 seconds"),
        (300, "5 minutes"),
        (3_600, "1 hour")
    ])
    func limitReadsAsDuration(seconds: Int, words: String) {
        #expect(
            OptionsPaneView.queryTimeoutInheritance(globalSeconds: seconds, locale: english)
                == "Leave blank to use Settings > Connections: \(words)."
        )
    }

    @Test("The prompt inside the seconds field keeps the number")
    func placeholderKeepsSeconds() {
        #expect(OptionsPaneView.queryTimeoutPlaceholder(globalSeconds: 60) == "Global (60)")
    }

    @Test("An out-of-range global value shows what a connection actually gets")
    func outOfRangeGlobalIsClamped() {
        #expect(OptionsPaneView.queryTimeoutPlaceholder(globalSeconds: -5) == "No limit")
        #expect(
            OptionsPaneView.queryTimeoutPlaceholder(globalSeconds: 9_999_999)
                == "Global (\(DatabaseConnection.queryTimeoutSecondsRange.upperBound))"
        )
    }
}
