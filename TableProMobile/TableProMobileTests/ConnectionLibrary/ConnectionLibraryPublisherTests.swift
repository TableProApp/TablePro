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
