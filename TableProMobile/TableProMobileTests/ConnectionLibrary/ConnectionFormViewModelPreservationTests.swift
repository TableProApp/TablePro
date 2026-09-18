import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection form keeps the fields it does not show")
struct ConnectionFormViewModelPreservationTests {
    @Test("Saving an edit keeps the order, color, timeout, favorite and extra tags")
    func keepsUneditedFields() {
        let first = UUID()
        let second = UUID()
        let stored = DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            color: .red,
            queryTimeoutSeconds: 30,
            tagIds: [first, second],
            sortOrder: 7,
            isFavorite: true
        )
        let viewModel = ConnectionFormViewModel(editing: stored)
        viewModel.name = "Production"

        let built = viewModel.buildConnection()

        #expect(built.id == stored.id)
        #expect(built.name == "Production")
        #expect(built.sortOrder == 7)
        #expect(built.color == .red)
        #expect(built.queryTimeoutSeconds == 30)
        #expect(built.isFavorite)
        #expect(built.tagIds == [first, second])
    }

    @Test("The legacy read-only flag follows the Safe Mode level")
    func readOnlyFollowsSafeMode() {
        let stored = DatabaseConnection(name: "Prod", type: .mysql, isReadOnly: true, safeModeLevel: .readOnly)
        let viewModel = ConnectionFormViewModel(editing: stored)
        viewModel.safeModeLevel = .off

        #expect(!viewModel.buildConnection().isReadOnly)
    }

    @Test("Picking a tag replaces only the tag the form shows")
    func tagSelection() {
        let shown = UUID()
        let other = UUID()
        let picked = UUID()

        #expect(ConnectionFormEdits.tagIds(selecting: picked, over: [shown, other]) == [picked, other])
        #expect(ConnectionFormEdits.tagIds(selecting: nil, over: [shown, other]) == [other])
        #expect(ConnectionFormEdits.tagIds(selecting: other, over: [shown, other]) == [other])
        #expect(ConnectionFormEdits.tagIds(selecting: shown, over: []) == [shown])
    }
}
