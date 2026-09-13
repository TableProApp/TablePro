import Foundation
@testable import TablePro
import Testing

@Suite("UpdateCheckFrequency")
struct UpdateCheckFrequencyTests {
    @Test("Raw values are the intervals Sparkle expects, in seconds")
    func rawValuesAreSeconds() {
        #expect(UpdateCheckFrequency.daily.rawValue == 86_400)
        #expect(UpdateCheckFrequency.weekly.rawValue == 604_800)
        #expect(UpdateCheckFrequency.daily.seconds == 86_400)
        #expect(UpdateCheckFrequency.weekly.seconds == 604_800)
    }

    @Test("Every case is offered and titled")
    func everyCaseIsTitled() {
        #expect(UpdateCheckFrequency.allCases == [.daily, .weekly])
        for frequency in UpdateCheckFrequency.allCases {
            #expect(!frequency.title.isEmpty)
            #expect(frequency.id == frequency.rawValue)
        }
    }

    @Test("Both intervals stay below the 14 day impatient interval in Info.plist")
    func staysBelowTheImpatientInterval() {
        // Sparkle documents SUScheduledImpatientCheckInterval as needing to be the larger of the
        // two, so a frequency above it would be a misconfiguration rather than a longer wait.
        let impatientInterval: TimeInterval = 1_209_600
        for frequency in UpdateCheckFrequency.allCases {
            #expect(frequency.seconds < impatientInterval)
        }
    }

    @Test("An exact interval resolves to its own case")
    func resolvesAnExactInterval() {
        #expect(UpdateCheckFrequency.closest(to: 86_400) == .daily)
        #expect(UpdateCheckFrequency.closest(to: 604_800) == .weekly)
    }

    @Test("An interval no case offers resolves to the nearest one")
    func resolvesAnArbitraryInterval() {
        // A managed preference or an older build can leave any number here, and the picker has to
        // show something rather than nothing.
        #expect(UpdateCheckFrequency.closest(to: 3600) == .daily)
        #expect(UpdateCheckFrequency.closest(to: 0) == .daily)
        #expect(UpdateCheckFrequency.closest(to: 200_000) == .daily)
        #expect(UpdateCheckFrequency.closest(to: 500_000) == .weekly)
        #expect(UpdateCheckFrequency.closest(to: 2_629_800) == .weekly)
    }
}
