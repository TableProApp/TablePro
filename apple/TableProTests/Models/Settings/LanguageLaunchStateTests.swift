import Foundation
@testable import TablePro
import Testing

@MainActor
struct LanguageLaunchStateTests {
    @Test("Nothing is captured before the launch records a language")
    func emptyUntilRecorded() {
        #expect(LaunchLanguage().language == nil)
    }

    @Test("The first recorded language stays after a later record or a general settings change")
    func firstRecordWins() {
        var launch = LaunchLanguage()

        #expect(launch.capture(.vietnamese) == .vietnamese)
        #expect(launch.capture(.french) == .vietnamese)
        #expect(launch.language == .vietnamese)
    }

    @Test("The app's launch language ignores a record after launch")
    func appLaunchLanguageIgnoresLaterRecord() {
        let launched = LanguageLaunchState.language

        LanguageLaunchState.record()

        #expect(LanguageLaunchState.language == launched)
    }
}
