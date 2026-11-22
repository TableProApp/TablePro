import Foundation
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorStoreOptionsTests {
    private let english = Locale(identifier: "en_US")

    @Test("No global limit reads as no limit, never as zero")
    func zeroReadsAsNoLimit() {
        #expect(
            QueryTimeoutInheritance.subtitle(globalSeconds: 0, locale: english)
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
            QueryTimeoutInheritance.subtitle(globalSeconds: seconds, locale: english)
                == "Leave blank to use Settings > Connections: \(words)."
        )
    }

    @Test("An out-of-range global value shows what a connection actually gets")
    func outOfRangeGlobalIsClamped() {
        #expect(QueryTimeoutInheritance.inheritedSeconds(globalSeconds: -5) == 0)
        #expect(
            QueryTimeoutInheritance.inheritedSeconds(globalSeconds: 9_999_999)
                == DatabaseConnection.queryTimeoutSecondsRange.upperBound
        )
    }

    @Test("Startup commands are SQL only for an engine whose editor speaks SQL")
    func startupCommandsLanguage() throws {
        let fixture = try ConnectionEditorStoreFixture()
        #expect(fixture.makeStore(.new(type: .postgresql, parsedURL: nil)).startupCommandsAreSQL)
        #expect(!fixture.makeStore(.new(type: .redis, parsedURL: nil)).startupCommandsAreSQL)
    }

    @Test("The read-only note follows the External Clients level")
    func readOnlyNoteFollowsAccess() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update { $0.ai.externalAccess = .readOnly }
        #expect(store.externalClientsReadOnlyNote != nil)
        store.update { $0.ai.externalAccess = .readWrite }
        #expect(store.externalClientsReadOnlyNote == nil)
    }
}
