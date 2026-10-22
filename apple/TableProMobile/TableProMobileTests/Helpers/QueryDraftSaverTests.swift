import Foundation
@testable import TableProMobile
import Testing

@MainActor
struct QueryDraftSaverTests {
    private let connectionId = UUID()
    private let suite = "QueryDraftSaverTests.\(UUID().uuidString)"

    private func defaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Text typed just before the editor goes away is saved by the flush")
    func flushSavesThePendingText() throws {
        let defaults = try defaults()
        let saver = QueryDraftSaver(defaults: defaults)

        saver.textChanged("SELECT 1", for: connectionId)
        #expect(saver.restore(for: connectionId) == nil)
        saver.flush()

        #expect(saver.restore(for: connectionId) == "SELECT 1")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("The newest text wins over a save still waiting")
    func newestTextWins() throws {
        let defaults = try defaults()
        let saver = QueryDraftSaver(defaults: defaults)

        saver.textChanged("SELECT", for: connectionId)
        saver.textChanged("SELECT 2", for: connectionId)
        saver.flush()

        #expect(saver.restore(for: connectionId) == "SELECT 2")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("A flush with nothing typed keeps the saved text")
    func flushWithoutEditsKeepsText() throws {
        let defaults = try defaults()
        defaults.set("SELECT 3", forKey: ConnectionDefaultsKey.lastQuery.name(for: connectionId))
        let saver = QueryDraftSaver(defaults: defaults)

        saver.flush()

        #expect(saver.restore(for: connectionId) == "SELECT 3")
        defaults.removePersistentDomain(forName: suite)
    }
}
