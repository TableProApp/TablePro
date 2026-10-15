import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @MainActor
    struct AppSettingsTraitTests {
        @Test("The trait writes a group only when it differs, then puts it back", arguments: [true, false])
        func writesOnlyWhatDiffers(enabled: Bool) async throws {
            let manager = AppSettingsManager.shared
            let before = manager.ai
            var writes = 0
            let subscription = AppEvents.shared.aiSettingsChanged.sink { writes += 1 }
            defer { subscription.cancel() }

            try await AppSettingsTrait.appSettings { $0.ai.enabled = enabled }
                .provideScope(for: try #require(Test.current), testCase: Test.Case.current) {
                    let inside = await MainActor.run { AppSettingsManager.shared.ai.enabled }
                    #expect(inside == enabled)
                }

            #expect(manager.ai == before)
            #expect(writes == (before.enabled == enabled ? 0 : 2))
        }
    }

    @Suite(.recordingClipboard)
    @MainActor
    struct RecordingClipboardTraitTests {
        @Test("Every copy path reaches the fake the trait installed")
        func installsTheFake() throws {
            let clipboard = try #require(RecordingClipboard.current)
            ClipboardService.shared.writeText("SELECT 1")
            #expect(clipboard.writes == ["SELECT 1"])
            #expect(clipboard.readText() == "SELECT 1")
        }

        @Test("A write replaces the rows an earlier copy left")
        func writeReplacesEarlierRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let rows = GridRowsClipboardPayload(columns: ["id"], rows: [[.text("1")]])
            clipboard.writeRows(tsv: "1", html: "<td>1</td>", gridRows: rows)
            #expect(clipboard.hasGridRows)
            #expect(clipboard.html == "<td>1</td>")

            clipboard.writeText("plain")
            #expect(!clipboard.hasGridRows)
            #expect(clipboard.html == nil)
            #expect(clipboard.writes == ["1", "plain"])
        }
    }

    @MainActor
    struct RecordingClipboardRestoreTests {
        @Test("The real clipboard is back once the scope ends")
        func restoresTheRealClipboard() async throws {
            #expect(!(ClipboardService.shared is RecordingClipboard))
            try await RecordingClipboardTrait.recordingClipboard
                .provideScope(for: try #require(Test.current), testCase: Test.Case.current) {
                    let swapped = await MainActor.run { ClipboardService.shared is RecordingClipboard }
                    #expect(swapped)
                }
            #expect(!(ClipboardService.shared is RecordingClipboard))
        }
    }
}

struct EphemeralDefaultsTests {
    @Test("The suite lives in a temporary directory that goes away with it")
    func leavesNothingBehind() throws {
        let directory = try Self.useASuite()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private static func useASuite() throws -> URL {
        let suite = try EphemeralDefaults()
        #expect(suite.suiteName.hasPrefix(FileManager.default.temporaryDirectory.path))
        suite.defaults.set("value", forKey: "key")
        #expect(suite.defaults.string(forKey: "key") == "value")
        #expect(try EphemeralDefaults().defaults.string(forKey: "key") == nil)
        return URL(fileURLWithPath: suite.suiteName).deletingLastPathComponent()
    }
}

struct PluginDriverStubTests {
    private final class QuotingStub: PluginDriverStub, @unchecked Sendable {
        func quoteIdentifier(_ name: String) -> String { "<\(name)>" }
    }

    @Test("A double's own member answers through the protocol, the rest come from the stub")
    func ownMemberWins() async throws {
        let driver: any PluginDatabaseDriver = QuotingStub()
        #expect(driver.quoteIdentifier("users") == "<users>")
        #expect(try await driver.fetchDatabases().isEmpty)
        #expect(try await driver.execute(query: "SELECT 1").rows.isEmpty)
        #expect(try await driver.fetchTableMetadata(table: "users", schema: nil).tableName == "users")
    }
}

@MainActor
struct CoordinatorFixtureTests {
    @Test("Releasing the fixture tears the coordinator down and drops the injected session")
    func releaseTearsDown() throws {
        let connection = TestFixtures.makeConnection()
        var fixture: CoordinatorFixture? = CoordinatorFixture(
            connection: connection,
            driver: ScriptAnsweringDriver(connection: connection)
        )
        let coordinator = try #require(fixture?.coordinator)
        #expect(DatabaseManager.shared.session(for: connection.id) != nil)
        #expect(!coordinator.isTearingDown)

        fixture = nil

        #expect(coordinator.isTearingDown)
        #expect(DatabaseManager.shared.session(for: connection.id) == nil)
    }

    @Test("An added tab becomes the selected tab")
    func addTabSelects() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(QueryTab(title: "Q1", query: "SELECT 1", tabType: .query))
        #expect(fixture.tabManager.selectedTabId == tab.id)
        #expect(fixture.tabManager.tabs.map(\.id) == [tab.id])
    }
}
