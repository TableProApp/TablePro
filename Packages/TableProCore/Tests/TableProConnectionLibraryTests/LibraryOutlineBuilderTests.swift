import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Library outline builder")
struct LibraryOutlineBuilderTests {
    @Test("Groups come before connections and every nesting depth is drawn")
    func drawsEveryDepth() {
        let level1 = FixtureGroup(name: "One")
        let level2 = FixtureGroup(name: "Two", parentId: level1.id)
        let level3 = FixtureGroup(name: "Three", parentId: level2.id)
        let level4 = FixtureGroup(name: "Four", parentId: level3.id)
        let level5 = FixtureGroup(name: "Five", parentId: level4.id)
        let deep = FixtureConnection(name: "deep", groupId: level5.id)
        let loose = FixtureConnection(name: "loose")

        let outline = LibraryOutlineBuilder.build(request(
            connections: [loose, deep],
            groups: [level5, level4, level3, level2, level1]
        ))

        let tree = outline.section(.connections)?.nodes ?? []
        #expect(childIds(tree) == [level1.id, loose.id])
        let fifth = findGroup(level5.id, in: tree)
        #expect(fifth.map { childIds($0.children) } == [deep.id])
        #expect(findGroup(level1.id, in: tree)?.connectionCount == 1)
    }

    @Test("A parent cycle is drawn at the top level instead of disappearing")
    func rootsCycles() {
        var first = FixtureGroup(name: "First")
        var second = FixtureGroup(name: "Second")
        first.parentId = second.id
        second.parentId = first.id
        let inside = FixtureConnection(name: "inside", groupId: first.id)

        let outline = LibraryOutlineBuilder.build(request(connections: [inside], groups: [first, second]))

        let tree = outline.section(.connections)?.nodes ?? []
        #expect(Set(childIds(tree)) == [first.id, second.id])
        #expect(outline.connectionIdsInDisplayOrder == [inside.id])
    }

    @Test("A connection whose group is gone is ungrouped")
    func orphanedConnectionIsUngrouped() {
        let orphan = FixtureConnection(name: "orphan", groupId: UUID())
        let outline = LibraryOutlineBuilder.build(request(connections: [orphan]))
        #expect(outline.section(.connections)?.nodes == [.connection(id: orphan.id)])
    }

    @Test("Manual order uses sortOrder and breaks ties with a numeric name compare")
    func manualOrder() {
        let db10 = FixtureConnection(name: "db10", sortOrder: 0)
        let db9 = FixtureConnection(name: "db9", sortOrder: 0)
        let first = FixtureConnection(name: "zeta", sortOrder: -1)
        let outline = LibraryOutlineBuilder.build(request(connections: [db10, db9, first]))
        #expect(outline.connectionIds(in: .connections) == [first.id, db9.id, db10.id])
    }

    @Test("Name sort ignores sortOrder")
    func nameOrder() {
        let beta = FixtureConnection(name: "beta", sortOrder: 0)
        let alpha = FixtureConnection(name: "Alpha", sortOrder: 9)
        let outline = LibraryOutlineBuilder.build(request(connections: [beta, alpha], sortMode: .name))
        #expect(outline.connectionIds(in: .connections) == [alpha.id, beta.id])
    }

    @Test("Database type sort groups engines then orders by name")
    func databaseTypeOrder() {
        let pgB = FixtureConnection(name: "b", libraryTypeName: "PostgreSQL")
        let mysql = FixtureConnection(name: "z", libraryTypeName: "MySQL")
        let pgA = FixtureConnection(name: "a", libraryTypeName: "PostgreSQL")
        let outline = LibraryOutlineBuilder.build(request(connections: [pgB, mysql, pgA], sortMode: .databaseType))
        #expect(outline.connectionIds(in: .connections) == [mysql.id, pgA.id, pgB.id])
    }

    @Test("Last connected sort puts the newest first and never-connected last")
    func lastConnectedOrder() {
        let never = FixtureConnection(name: "a-never")
        let old = FixtureConnection(name: "old")
        let recent = FixtureConnection(name: "recent")
        let now = Date(timeIntervalSince1970: 1_000)
        let outline = LibraryOutlineBuilder.build(request(
            connections: [never, old, recent],
            sortMode: .lastConnected,
            lastConnected: [old.id: now.addingTimeInterval(-60), recent.id: now]
        ))
        #expect(outline.connectionIds(in: .connections) == [recent.id, old.id, never.id])
    }

    @Test("Groups keep manual order only in manual sort")
    func groupOrder() {
        let zeta = FixtureGroup(name: "Zeta", sortOrder: 0)
        let alpha = FixtureGroup(name: "Alpha", sortOrder: 1)
        let manual = LibraryOutlineBuilder.build(request(connections: [], groups: [alpha, zeta]))
        let byName = LibraryOutlineBuilder.build(request(connections: [], groups: [alpha, zeta], sortMode: .name))
        #expect(childIds(manual.section(.connections)?.nodes ?? []) == [zeta.id, alpha.id])
        #expect(childIds(byName.section(.connections)?.nodes ?? []) == [alpha.id, zeta.id])
    }

    @Test("A favorite appears in Favorites and still in its group, with distinct row identities")
    func favoriteAppearsTwice() {
        let group = FixtureGroup(name: "Work")
        let favorite = FixtureConnection(name: "prod", groupId: group.id, isFavorite: true)
        let outline = LibraryOutlineBuilder.build(request(connections: [favorite], groups: [group]))

        #expect(outline.connectionIds(in: .favorites) == [favorite.id])
        #expect(outline.connectionIds(in: .connections) == [favorite.id])
        let favoriteRow = LibraryNode.connection(id: favorite.id).rowID(in: .favorites)
        let treeRow = LibraryNode.connection(id: favorite.id).rowID(in: .connections)
        #expect(favoriteRow != treeRow)
        #expect(outline.connectionIdsInDisplayOrder == [favorite.id])
    }

    @Test("Favorites follow the device order in manual sort and new favorites go last by name")
    func favoritesOrder() {
        let first = FixtureConnection(name: "zulu", isFavorite: true)
        let second = FixtureConnection(name: "alpha", isFavorite: true)
        let unordered = FixtureConnection(name: "bravo", isFavorite: true)
        let outline = LibraryOutlineBuilder.build(request(
            connections: [second, unordered, first],
            favoritesOrder: [first.id, second.id]
        ))
        #expect(outline.connectionIds(in: .favorites) == [first.id, second.id, unordered.id])
    }

    @Test("Recent lists the five newest connections that are not favorites")
    func recentSection() {
        let base = Date(timeIntervalSince1970: 10_000)
        var connections: [FixtureConnection] = []
        var dates: [UUID: Date] = [:]
        for index in 0..<7 {
            let connection = FixtureConnection(name: "c\(index)", isFavorite: index == 6)
            connections.append(connection)
            dates[connection.id] = base.addingTimeInterval(Double(index))
        }
        dates[UUID()] = base.addingTimeInterval(100)

        let outline = LibraryOutlineBuilder.build(request(connections: connections, lastConnected: dates))

        let expected = [5, 4, 3, 2, 1].map { connections[$0].id }
        #expect(outline.connectionIds(in: .recent) == expected)
    }

    @Test("Recent can be hidden without changing the connection list")
    func recentSectionHidden() {
        let recent = FixtureConnection(name: "recent")
        let outline = LibraryOutlineBuilder.build(request(
            connections: [recent],
            lastConnected: [recent.id: Date()],
            includesRecent: false
        ))

        #expect(outline.section(.recent) == nil)
        #expect(outline.connectionIds(in: .connections) == [recent.id])
    }

    @Test("Favorites and Recent are hidden while searching")
    func searchHidesAliasSections() {
        let favorite = FixtureConnection(name: "prod", isFavorite: true)
        let outline = LibraryOutlineBuilder.build(request(
            connections: [favorite],
            query: LibraryQuery(text: "prod"),
            lastConnected: [favorite.id: Date()]
        ))
        #expect(outline.section(.favorites) == nil)
        #expect(outline.section(.recent) == nil)
        #expect(outline.connectionIds(in: .connections) == [favorite.id])
        #expect(outline.isQueryActive)
    }

    @Test("A match inside a nested group expands its ancestors")
    func searchExpandsAncestors() {
        let outer = FixtureGroup(name: "Clients")
        let inner = FixtureGroup(name: "Acme", parentId: outer.id)
        let match = FixtureConnection(name: "orders", groupId: inner.id)
        let other = FixtureConnection(name: "billing", groupId: inner.id)

        let outline = LibraryOutlineBuilder.build(request(
            connections: [match, other],
            groups: [outer, inner],
            query: LibraryQuery(text: "ORDERS")
        ))

        #expect(outline.connectionIdsInDisplayOrder == [match.id])
        #expect(outline.groupIdsExpandedByQuery == [outer.id, inner.id])
    }

    @Test("Text matches host, database, username, type and tag names")
    func searchFields() {
        let tag = FixtureTag(name: "staging")
        let byHost = FixtureConnection(name: "a", host: "db.acme.io")
        let byDatabase = FixtureConnection(name: "b", database: "acme_prod")
        let byUser = FixtureConnection(name: "c", username: "acme_admin")
        let byTag = FixtureConnection(name: "d", tagIds: [tag.id])
        let byType = FixtureConnection(name: "e", libraryTypeName: "ClickHouse")
        let miss = FixtureConnection(name: "f")
        let all = [byHost, byDatabase, byUser, byTag, byType, miss]

        let acme = LibraryOutlineBuilder.build(request(connections: all, tags: [tag], query: LibraryQuery(text: "acme")))
        let staging = LibraryOutlineBuilder.build(request(connections: all, tags: [tag], query: LibraryQuery(text: "stag")))
        let clickhouse = LibraryOutlineBuilder.build(request(connections: all, tags: [tag], query: LibraryQuery(text: "click")))

        #expect(Set(acme.connectionIdsInDisplayOrder) == [byHost.id, byDatabase.id, byUser.id])
        #expect(staging.connectionIdsInDisplayOrder == [byTag.id])
        #expect(clickhouse.connectionIdsInDisplayOrder == [byType.id])
    }

    @Test("A group whose name matches keeps all of its connections")
    func groupNameMatch() {
        let group = FixtureGroup(name: "Production")
        let inside = FixtureConnection(name: "orders", groupId: group.id)
        let empty = FixtureGroup(name: "Production archive")

        let outline = LibraryOutlineBuilder.build(request(
            connections: [inside],
            groups: [group, empty],
            query: LibraryQuery(text: "product")
        ))

        let tree = outline.section(.connections)?.nodes ?? []
        #expect(Set(childIds(tree)) == [group.id, empty.id])
        #expect(outline.connectionIdsInDisplayOrder == [inside.id])
    }

    @Test("Tag tokens match any or all and combine with text")
    func tagTokens() {
        let prod = FixtureTag(name: "prod")
        let europe = FixtureTag(name: "eu")
        let both = FixtureConnection(name: "orders-eu", tagIds: [prod.id, europe.id])
        let prodOnly = FixtureConnection(name: "orders-us", tagIds: [prod.id])
        let euOnly = FixtureConnection(name: "billing-eu", tagIds: [europe.id])
        let all = [both, prodOnly, euOnly]
        let tags = [prod, europe]

        let any = LibraryOutlineBuilder.build(request(
            connections: all, tags: tags,
            query: LibraryQuery(tagIds: [prod.id, europe.id], tagMatch: .any)
        ))
        let every = LibraryOutlineBuilder.build(request(
            connections: all, tags: tags,
            query: LibraryQuery(tagIds: [prod.id, europe.id], tagMatch: .all)
        ))
        let withText = LibraryOutlineBuilder.build(request(
            connections: all, tags: tags,
            query: LibraryQuery(text: "orders", tagIds: [europe.id])
        ))

        #expect(Set(any.connectionIdsInDisplayOrder) == [both.id, prodOnly.id, euOnly.id])
        #expect(every.connectionIdsInDisplayOrder == [both.id])
        #expect(withText.connectionIdsInDisplayOrder == [both.id])
    }

    @Test("A tag filter drops empty groups")
    func tagFilterDropsEmptyGroups() {
        let tag = FixtureTag(name: "prod")
        let group = FixtureGroup(name: "Other")
        let untagged = FixtureConnection(name: "x", groupId: group.id)
        let outline = LibraryOutlineBuilder.build(request(
            connections: [untagged], groups: [group], tags: [tag],
            query: LibraryQuery(tagIds: [tag.id])
        ))
        #expect(outline.section(.connections) == nil)
        #expect(outline.isEmpty)
    }

    @Test("Without a query empty groups are still drawn")
    func emptyGroupsDrawn() {
        let group = FixtureGroup(name: "Empty")
        let outline = LibraryOutlineBuilder.build(request(connections: [], groups: [group]))
        #expect(outline.section(.connections)?.nodes == [.group(id: group.id, children: [], connectionCount: 0)])
    }

    @Test("External sections filter by text and disappear under a tag filter")
    func externalSections() {
        let entry = LibraryExternalEntry(id: UUID(), name: "shared-prod", host: "h", database: "d", username: "u", typeName: "MySQL")
        let other = LibraryExternalEntry(id: UUID(), name: "analytics", host: "h", database: "d", username: "u", typeName: "MySQL")
        let sections = [LibraryExternalSection(kind: .linkedFolders, entries: [other, entry])]

        let plain = LibraryOutlineBuilder.build(request(connections: [], externalSections: sections))
        let text = LibraryOutlineBuilder.build(request(connections: [], query: LibraryQuery(text: "prod"), externalSections: sections))
        let tagged = LibraryOutlineBuilder.build(request(
            connections: [], query: LibraryQuery(tagIds: [UUID()]), externalSections: sections
        ))

        #expect(plain.connectionIds(in: .linkedFolders) == [other.id, entry.id])
        #expect(text.connectionIds(in: .linkedFolders) == [entry.id])
        #expect(tagged.section(.linkedFolders) == nil)
    }

    @Test("Section order is Favorites, Recent, Connections, then external sections")
    func sectionOrder() {
        let favorite = FixtureConnection(name: "fav", isFavorite: true)
        let plain = FixtureConnection(name: "plain")
        let entry = LibraryExternalEntry(id: UUID(), name: "team", host: "", database: "", username: "", typeName: "")
        let outline = LibraryOutlineBuilder.build(request(
            connections: [favorite, plain],
            lastConnected: [plain.id: Date()],
            externalSections: [LibraryExternalSection(kind: .teamLibrary, entries: [entry])]
        ))
        #expect(outline.sections.map(\.kind) == [.favorites, .recent, .connections, .teamLibrary])
    }
}
