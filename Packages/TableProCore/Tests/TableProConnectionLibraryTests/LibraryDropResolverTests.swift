import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Library drop resolver")
struct LibraryDropResolverTests {
    private struct Library {
        let work = FixtureGroup(name: "Work", sortOrder: 0)
        let home: FixtureGroup
        let alpha: FixtureConnection
        let beta: FixtureConnection
        let loose: FixtureConnection
        let favorite: FixtureConnection

        init() {
            home = FixtureGroup(name: "Home", sortOrder: 1)
            alpha = FixtureConnection(name: "alpha", groupId: work.id, sortOrder: 0)
            beta = FixtureConnection(name: "beta", groupId: work.id, sortOrder: 1)
            loose = FixtureConnection(name: "loose")
            favorite = FixtureConnection(name: "starred", isFavorite: true)
        }

        var connections: [FixtureConnection] { [alpha, beta, loose, favorite] }
        var groups: [FixtureGroup] { [work, home] }

        func resolve(
            _ items: [LibraryDragItem],
            onto target: LibraryDropTarget,
            sortMode: LibrarySortMode = .manual
        ) -> LibraryDropResolution? {
            let outline = LibraryOutlineBuilder.build(request(connections: connections, groups: groups, sortMode: sortMode))
            return LibraryDropResolver.resolve(
                items: items,
                target: target,
                sortMode: sortMode,
                graph: LibraryGroupGraph(groups: groups),
                connections: Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) }),
                outline: outline
            )
        }
    }

    @Test("Dropping a connection onto a group moves it there")
    func dropOntoGroup() {
        let library = Library()
        let result = library.resolve([.connection(library.loose.id, section: .connections)], onto: .group(library.home.id, childIndex: nil))
        #expect(result?.operation == .moveConnections([library.loose.id], toGroup: library.home.id, before: nil))
    }

    @Test("Dropping between connections in manual sort places it before the next one")
    func reorderInManual() {
        let library = Library()
        let result = library.resolve(
            [.connection(library.loose.id, section: .connections)],
            onto: .group(library.work.id, childIndex: 1)
        )
        #expect(result?.operation == .moveConnections([library.loose.id], toGroup: library.work.id, before: library.beta.id))
    }

    @Test("A reorder drop is retargeted onto the group when the list is sorted")
    func retargetsWhenSorted() {
        let library = Library()
        let result = library.resolve(
            [.connection(library.loose.id, section: .connections)],
            onto: .group(library.work.id, childIndex: 1),
            sortMode: .name
        )
        #expect(result?.operation == .moveConnections([library.loose.id], toGroup: library.work.id, before: nil))
        #expect(result?.target == .group(library.work.id, childIndex: nil))
    }

    @Test("A sorted drop into the group a connection is already in does nothing")
    func sortedNoOp() {
        let library = Library()
        let result = library.resolve(
            [.connection(library.alpha.id, section: .connections)],
            onto: .group(library.work.id, childIndex: 0),
            sortMode: .name
        )
        #expect(result == nil)
    }

    @Test("Dropping onto the Connections section ungroups")
    func dropOntoRoot() {
        let library = Library()
        let result = library.resolve(
            [.connection(library.alpha.id, section: .connections)],
            onto: .section(.connections, childIndex: nil)
        )
        #expect(result?.operation == .moveConnections([library.alpha.id], toGroup: nil, before: nil))
    }

    @Test("Dropping onto Favorites adds a favorite")
    func dropOntoFavorites() {
        let library = Library()
        let result = library.resolve([.connection(library.alpha.id, section: .connections)], onto: .section(.favorites, childIndex: nil))
        #expect(result?.operation == .addFavorites([library.alpha.id], before: nil))
    }

    @Test("Dragging within Favorites reorders only in manual sort")
    func reorderFavorites() {
        let library = Library()
        let manual = library.resolve([.connection(library.favorite.id, section: .favorites)], onto: .section(.favorites, childIndex: 0))
        let sorted = library.resolve(
            [.connection(library.favorite.id, section: .favorites)],
            onto: .section(.favorites, childIndex: 0),
            sortMode: .name
        )
        #expect(manual?.operation == .reorderFavorites([library.favorite.id], before: nil))
        #expect(sorted == nil)
    }

    @Test("Recent, Linked Folders and Team Library refuse drops")
    func refusedSections() {
        let library = Library()
        let item = LibraryDragItem.connection(library.loose.id, section: .connections)
        #expect(library.resolve([item], onto: .section(.recent, childIndex: nil)) == nil)
        #expect(library.resolve([item], onto: .section(.linkedFolders, childIndex: nil)) == nil)
        #expect(library.resolve([item], onto: .section(.teamLibrary, childIndex: nil)) == nil)
    }

    @Test("Shared connections cannot be dragged")
    func externalItemsRefused() {
        let library = Library()
        let result = library.resolve([.connection(UUID(), section: .linkedFolders)], onto: .group(library.work.id, childIndex: nil))
        #expect(result == nil)
    }

    @Test("A group and a connection cannot be dragged together")
    func mixedDragRefused() {
        let library = Library()
        let result = library.resolve(
            [.group(library.home.id), .connection(library.loose.id, section: .connections)],
            onto: .section(.connections, childIndex: nil)
        )
        #expect(result == nil)
    }

    @Test("Moving a group into itself is refused")
    func groupIntoItselfRefused() {
        let library = Library()
        #expect(library.resolve([.group(library.work.id)], onto: .group(library.work.id, childIndex: nil)) == nil)
    }

    @Test("Nesting a group is allowed and reordering groups places them before the next group")
    func groupMoves() {
        let library = Library()
        let nest = library.resolve([.group(library.home.id)], onto: .group(library.work.id, childIndex: nil))
        let reorder = library.resolve([.group(library.home.id)], onto: .section(.connections, childIndex: 0))
        #expect(nest?.operation == .moveGroups([library.home.id], toParent: library.work.id, before: nil))
        #expect(reorder?.operation == .moveGroups([library.home.id], toParent: nil, before: library.work.id))
    }

    @Test("A drop that would nest past the cap is refused while dragging")
    func depthCapRefused() {
        let one = FixtureGroup(name: "1")
        let two = FixtureGroup(name: "2", parentId: one.id)
        let three = FixtureGroup(name: "3", parentId: two.id)
        let moving = FixtureGroup(name: "moving")
        let groups = [one, two, three, moving]
        let outline = LibraryOutlineBuilder.build(request(connections: [], groups: groups))
        let result = LibraryDropResolver.resolve(
            items: [.group(moving.id)],
            target: .group(three.id, childIndex: nil),
            sortMode: .manual,
            graph: LibraryGroupGraph(groups: groups),
            connections: [UUID: FixtureConnection](),
            outline: outline
        )
        #expect(result == nil)
    }
}
