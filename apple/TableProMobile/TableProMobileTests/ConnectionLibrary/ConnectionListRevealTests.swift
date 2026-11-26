import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

struct ConnectionListRevealTests {
    private let team = ConnectionGroup(name: "Team")
    private let prod = ConnectionTag(name: "prod", color: .red)

    private func library(
        _ connections: [DatabaseConnection],
        groups: [ConnectionGroup],
        query: LibraryQuery
    ) -> LibraryOutlineRequest<DatabaseConnection, ConnectionGroup, ConnectionTag> {
        LibraryOutlineRequest(connections: connections, groups: groups, tags: [prod], sortMode: .name, query: query)
    }

    @Test("A batch import clears a search that hides one of them, opens the groups that hold them and scrolls to the first row")
    func batchClearsHidingSearch() throws {
        let staging = ConnectionGroup(name: "Staging", parentId: team.id)
        let analytics = DatabaseConnection(name: "Analytics", type: .postgresql)
        let billing = DatabaseConnection(name: "Billing", type: .mysql, groupId: staging.id)
        let archive = DatabaseConnection(name: "Archive", type: .postgresql)

        let reveal = try #require(ConnectionListReveal.plan(
            revealing: [analytics.id, billing.id],
            in: library([archive, analytics, billing], groups: [team, staging], query: LibraryQuery(text: "Billing")),
            collapsedGroupIds: [team.id, staging.id],
            isEditing: false
        ))

        #expect(reveal.clearsQuery)
        #expect(reveal.groupIdsToExpand == [team.id, staging.id])
        #expect(reveal.scrollTarget == .connection(billing.id, section: .connections))
        #expect(reveal.selection == nil)
    }

    @Test("A tag filter that hides one of them is cleared too")
    func batchClearsHidingTagFilter() throws {
        let tagged = DatabaseConnection(name: "Analytics", type: .postgresql, tagIds: [prod.id])
        let untagged = DatabaseConnection(name: "Billing", type: .mysql)

        let reveal = try #require(ConnectionListReveal.plan(
            revealing: [tagged.id, untagged.id],
            in: library([tagged, untagged], groups: [], query: LibraryQuery(tagIds: [prod.id])),
            collapsedGroupIds: [],
            isEditing: false
        ))

        #expect(reveal.clearsQuery)
        #expect(reveal.scrollTarget == .connection(tagged.id, section: .connections))
    }

    @Test("A search that already shows every imported connection is kept")
    func matchingSearchIsKept() throws {
        let billing = DatabaseConnection(name: "Billing", type: .mysql)
        let billingReplica = DatabaseConnection(name: "Billing Replica", type: .mysql)
        let analytics = DatabaseConnection(name: "Analytics", type: .postgresql)

        let reveal = try #require(ConnectionListReveal.plan(
            revealing: [billingReplica.id, billing.id],
            in: library([analytics, billing, billingReplica], groups: [], query: LibraryQuery(text: "Billing")),
            collapsedGroupIds: [],
            isEditing: false
        ))

        #expect(reveal.clearsQuery == false)
        #expect(reveal.scrollTarget == .connection(billing.id, section: .connections))
    }

    @Test("Only the collapsed groups on the way to an imported connection are opened")
    func opensOnlyCollapsedAncestors() throws {
        let staging = ConnectionGroup(name: "Staging", parentId: team.id)
        let archived = ConnectionGroup(name: "Archived")
        let billing = DatabaseConnection(name: "Billing", type: .mysql, groupId: staging.id)
        let analytics = DatabaseConnection(name: "Analytics", type: .postgresql)

        let reveal = try #require(ConnectionListReveal.plan(
            revealing: [billing.id, analytics.id],
            in: library([billing, analytics], groups: [team, staging, archived], query: LibraryQuery()),
            collapsedGroupIds: [staging.id, archived.id],
            isEditing: false
        ))

        #expect(reveal.groupIdsToExpand == [staging.id])
    }

    @Test("In edit mode the imported rows are marked, since a tap there selects instead of opening")
    func editModeMarksRows() throws {
        let analytics = DatabaseConnection(name: "Analytics", type: .postgresql)
        let billing = DatabaseConnection(name: "Billing", type: .mysql, isFavorite: true)

        let reveal = try #require(ConnectionListReveal.plan(
            revealing: [analytics.id, billing.id],
            in: library([analytics, billing], groups: [], query: LibraryQuery()),
            collapsedGroupIds: [],
            isEditing: true
        ))

        let marked: Set<LibraryRowID> = [
            .connection(analytics.id, section: .connections),
            .connection(billing.id, section: .connections)
        ]
        #expect(reveal.selection == marked)
    }

    @Test("Connections that left the library before the reveal are skipped, and none left reveals nothing")
    func goneConnectionsRevealNothing() {
        let analytics = DatabaseConnection(name: "Analytics", type: .postgresql)

        let reveal = ConnectionListReveal.plan(
            revealing: [UUID()],
            in: library([analytics], groups: [], query: LibraryQuery(text: "Billing")),
            collapsedGroupIds: [],
            isEditing: true
        )

        #expect(reveal == nil)
    }
}
