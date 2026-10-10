import Foundation
import Testing

@testable import TableProImport

@Suite("Import selection")
struct ImportSelectionTests {
    private typealias Fixtures = ImportFixtures

    private let existingId = UUID()

    private func makePreview(withQueries: Bool = false) throws -> ImportPreview {
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "First")),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Second")),
                BundleConnection(ref: "c3", settings: Fixtures.settings(name: "New", host: "new.example.com"))
            ],
            savedQueries: withQueries
                ? [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1")]
                : []
        )
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), id: existingId)])
        return Fixtures.makePreview(bundle, library: library)
    }

    @Test("Defaults select new connections and leave duplicates unchecked")
    func defaultsSelectNewConnections() throws {
        let selection = ImportSelection.defaults(for: try makePreview())

        #expect(selection.resolution(for: "c1") == nil)
        #expect(selection.resolution(for: "c2") == nil)
        #expect(selection.resolution(for: "c3") == .add)
        #expect(!selection.keepsCommands)
    }

    @Test("Checking a duplicate gives the row default")
    func checkingADuplicateGivesItsDefault() throws {
        let preview = try makePreview(withQueries: true)
        var selection = ImportSelection.defaults(for: preview)

        selection.setSelected(true, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c2", in: preview)

        #expect(selection.resolution(for: "c1") == .keepExisting(existingId))
        #expect(selection.resolution(for: "c2") == .addCopy)
    }

    @Test("A second Replace of the same connection is refused")
    func secondReplaceIsRefused() throws {
        let preview = try makePreview()
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c2", in: preview)

        let firstAccepted = selection.resolve("c1", as: .replace(existingId), in: preview)
        let secondAccepted = selection.resolve("c2", as: .replace(existingId), in: preview)

        #expect(firstAccepted)
        #expect(!secondAccepted)
        #expect(selection.resolution(for: "c2") == .addCopy)

        let second = try #require(preview.connectionRow("c2"))
        #expect(selection.offeredResolutions(for: second) == [.addCopy])
        let first = try #require(preview.connectionRow("c1"))
        #expect(selection.offeredResolutions(for: first) == [.addCopy, .replace(existingId)])
    }

    @Test("Unchecking the row that holds a Replace frees the target")
    func uncheckingFreesTheTarget() throws {
        let preview = try makePreview()
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c2", in: preview)
        selection.resolve("c1", as: .replace(existingId), in: preview)

        selection.setSelected(false, connection: "c1", in: preview)

        let accepted = selection.resolve("c2", as: .replace(existingId), in: preview)
        #expect(selection.resolution(for: "c1") == nil)
        #expect(accepted)
    }

    @Test("Re-checking a row whose Replace is now held falls back to its default")
    func recheckingAHeldReplaceFallsBack() throws {
        let preview = try makePreview()
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)
        selection.resolve("c1", as: .replace(existingId), in: preview)
        selection.setSelected(false, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c2", in: preview)
        selection.resolve("c2", as: .replace(existingId), in: preview)

        selection.setSelected(true, connection: "c1", in: preview)

        #expect(selection.resolution(for: "c1") == .addCopy)
        #expect(selection.resolution(for: "c2") == .replace(existingId))
    }

    @Test("A choice survives unchecking and re-checking the row")
    func choiceSurvivesUncheck() throws {
        let preview = try makePreview()
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)
        selection.resolve("c1", as: .replace(existingId), in: preview)

        selection.setSelected(false, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c1", in: preview)

        #expect(selection.resolution(for: "c1") == .replace(existingId))
    }

    @Test("A resolution the row does not offer is refused")
    func unofferedResolutionIsRefused() throws {
        let preview = try makePreview()
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)

        let attempts = [
            selection.resolve("c1", as: .add, in: preview),
            selection.resolve("c1", as: .replace(UUID()), in: preview),
            selection.resolve("c1", as: .keepExisting(existingId), in: preview),
            selection.resolve("c3", as: .addCopy, in: preview),
            selection.resolve("missing", as: .add, in: preview)
        ]

        #expect(attempts == [false, false, false, false, false])
        #expect(selection.resolution(for: "c1") == .addCopy)
    }

    @Test("A query override is stored until changed")
    func queryOverrideIsStored() throws {
        var selection = ImportSelection.defaults(for: try makePreview(withQueries: true))
        #expect(selection.queryOverride("q1") == nil)

        selection.setIncluded(false, query: "q1")
        #expect(selection.queryOverride("q1") == false)

        selection.setIncluded(true, query: "q1")
        #expect(selection.queryOverride("q1") == true)
    }
}
