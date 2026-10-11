import CoreSpotlight
import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection library publisher")
struct ConnectionLibraryPublisherTests {
    private final class Recorder {
        var shortcutRefreshes = 0
        var widgetWrites: [[WidgetConnectionItem]] = []
    }

    private let index = RecordingSearchIndex()
    private let recorder = Recorder()

    private func makePublisher() -> ConnectionLibraryPublisher {
        let recorder = recorder
        return ConnectionLibraryPublisher(
            searchIndex: index,
            writeWidgetItems: { recorder.widgetWrites.append($0) },
            refreshShortcutParameters: { recorder.shortcutRefreshes += 1 }
        )
    }

    private func connection(_ name: String, host: String = "db.example.com", sortOrder: Int = 0) -> DatabaseConnection {
        DatabaseConnection(name: name, type: .postgresql, host: host, port: 5_432, sortOrder: sortOrder)
    }

    @Test("Each publish replaces the whole domain, so a removed connection leaves the index")
    func publishReplacesTheDomain() async {
        let publisher = makePublisher()
        let first = connection("A")
        let second = connection("B")

        publisher.publish([first, second])
        await publisher.settle()
        publisher.publish([first])
        await publisher.settle()
        #expect(index.indexedIds == [first.id])

        publisher.publish([])
        await publisher.settle()
        #expect(index.contents.isEmpty)
        #expect(index.replacements.count == 3)
    }

    @Test("Publishes made in one turn cost one replace, with the newest list")
    func burstCoalesces() async {
        let publisher = makePublisher()
        let first = connection("A")
        let second = connection("B")
        let third = connection("C")

        publisher.publish([first])
        publisher.publish([first, second])
        publisher.publish([third])
        await publisher.settle()

        let replacements = index.replacements
        #expect(replacements.count == 1)
        #expect(replacements.first?.map(\.id) == [third.id])
    }

    @Test("A publish during a replace waits its turn, and only the newest of the waiting lists runs")
    func replacesNeverOverlap() async {
        let publisher = makePublisher()
        let first = connection("A")
        let second = connection("B")
        let third = connection("C")

        index.holdNextReplace()
        publisher.publish([first])
        await index.waitUntilHeld()
        publisher.publish([first, second])
        publisher.publish([third])
        index.release()
        await publisher.settle()

        #expect(index.replacements.map { $0.map(\.id) } == [[first.id], [third.id]])
        #expect(index.maxConcurrent == 1)
        #expect(index.indexedIds == [third.id])
    }

    @Test("Reordering or favoriting changes nothing the index or Shortcuts shows")
    func presentationOnlyChangesAreSkipped() async {
        let publisher = makePublisher()
        let first = connection("A")
        let second = connection("B")
        publisher.publish([first, second])
        await publisher.settle()

        var reordered = first
        reordered.sortOrder = 9
        var favorite = second
        favorite.isFavorite = true
        publisher.publish([favorite, reordered])
        await publisher.settle()

        #expect(index.replacements.count == 1)
        #expect(recorder.shortcutRefreshes == 1)
        #expect(recorder.widgetWrites.count == 2)
    }

    @Test("A failed replace is tried again on the next publish")
    func failureRetries() async {
        let publisher = makePublisher()
        let first = connection("A")
        index.failNext()

        publisher.publish([first])
        await publisher.settle()
        #expect(index.contents.isEmpty)

        publisher.publish([first])
        await publisher.settle()
        #expect(index.replacements.count == 2)
        #expect(index.indexedIds == [first.id])
    }

    @Test("Shortcut suggestions refresh on add, rename, host change and delete")
    func shortcutRefreshTriggers() async {
        let publisher = makePublisher()
        let first = connection("A")
        publisher.publish([first])
        #expect(recorder.shortcutRefreshes == 1)

        let second = connection("B")
        publisher.publish([first, second])
        #expect(recorder.shortcutRefreshes == 2)

        var renamed = second
        renamed.name = "Renamed"
        publisher.publish([first, renamed])
        #expect(recorder.shortcutRefreshes == 3)

        var rehosted = renamed
        rehosted.host = "replica.example.com"
        publisher.publish([first, rehosted])
        #expect(recorder.shortcutRefreshes == 4)

        publisher.publish([first])
        #expect(recorder.shortcutRefreshes == 5)
        await publisher.settle()
    }

    @Test("Widget items sort by order, then name, and a blank name shows the host")
    func widgetItemMapping() {
        let unnamed = DatabaseConnection(name: "", type: .mysql, host: "cache.local", sortOrder: 1)
        let later = connection("Zulu", sortOrder: 1)
        let first = connection("Alpha", sortOrder: 0)

        let items = ConnectionLibraryPublisher.widgetItems(for: [later, unnamed, first])

        #expect(items.map(\.name) == ["Alpha", "cache.local", "Zulu"])
        #expect(items.map(\.sortOrder) == [0, 1, 1])
    }

    @Test("A widget item draws the custom icon when this device can, and the engine glyph otherwise")
    func widgetItemGlyphPrefersCustomIcon() {
        let custom = DatabaseConnection(name: "A", type: .postgresql, iconName: "flame", sortOrder: 0)
        let unknown = DatabaseConnection(name: "B", type: .postgresql, iconName: "made.up.symbol", sortOrder: 1)
        let plain = DatabaseConnection(name: "C", type: .postgresql, sortOrder: 2)

        let glyphs = ConnectionLibraryPublisher.widgetItems(for: [custom, unknown, plain]).map(\.glyph)

        #expect(glyphs == [
            ConnectionGlyph(source: .symbol, name: "flame"),
            ConnectionGlyph(source: .asset, name: "postgresql-icon"),
            ConnectionGlyph(source: .asset, name: "postgresql-icon")
        ])
    }

    /// The widget kept its own copy of the engine glyph map, which had drifted from the list: a
    /// Dameng connection drew a drive in the widget and a cylinder in the list.
    @Test("A widget item draws the same engine glyph as the connection list")
    func widgetItemGlyphMatchesTheList() {
        let types: [DatabaseType] = [.dameng, .snowflake, .mysql, DatabaseType(rawValue: "FuturePlugin")]
        let connections = types.enumerated().map { index, type in
            DatabaseConnection(name: "C\(index)", type: type, sortOrder: index)
        }

        let glyphs = ConnectionLibraryPublisher.widgetItems(for: connections).map(\.glyph)

        #expect(glyphs == types.map { type -> ConnectionGlyph? in LibraryGlyph.engineGlyph(for: type) })
        #expect(glyphs.first == ConnectionGlyph(source: .symbol, name: "cylinder"))
        #expect(glyphs[1] == .fallback)
        #expect(glyphs[2] == ConnectionGlyph(source: .asset, name: "mysql-icon"))
    }

    @Test("A Spotlight item keeps the identifier and domain earlier builds indexed under")
    func spotlightItemFields() {
        let searchable = SearchableConnection(connection: connection("Orders"))
        let item = SpotlightConnectionIndex.searchableItem(for: searchable)

        #expect(item.uniqueIdentifier == searchable.id.uuidString)
        #expect(item.domainIdentifier == "com.TablePro.connections")
        #expect(item.attributeSet.title == "Orders")
        #expect(item.attributeSet.contentDescription == searchable.summary)
    }
}
