//
//  ConnectionFormRequestTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionFormRequest")
struct ConnectionFormRequestTests {
    @Test("Each create request is distinct so every new connection gets its own window")
    func eachCreateRequestIsDistinct() {
        let first = ConnectionFormRequest.create(draftId: UUID())
        let second = ConnectionFormRequest.create(draftId: UUID())
        #expect(first != second)
    }

    @Test("Editing the same connection produces the same request so its window is reused")
    func editRequestsForTheSameConnectionAreEqual() {
        let connectionId = UUID()
        let first = ConnectionFormRequest.edit(connectionId: connectionId)
        let second = ConnectionFormRequest.edit(connectionId: connectionId)
        #expect(first == second)
    }

    @Test("Editing different connections produces different requests")
    func editRequestsForDifferentConnectionsDiffer() {
        let first = ConnectionFormRequest.edit(connectionId: UUID())
        let second = ConnectionFormRequest.edit(connectionId: UUID())
        #expect(first != second)
    }

    @Test("A create request never collides with an edit request carrying the same id")
    func createNeverCollidesWithEdit() {
        let id = UUID()
        let create = ConnectionFormRequest.create(draftId: id)
        let edit = ConnectionFormRequest.edit(connectionId: id)
        #expect(create != edit)
    }

    @Test("Only an edit request exposes a connection id")
    func onlyEditExposesAConnectionId() {
        let connectionId = UUID()
        #expect(ConnectionFormRequest.edit(connectionId: connectionId).editedConnectionId == connectionId)
        #expect(ConnectionFormRequest.create(draftId: UUID()).editedConnectionId == nil)
    }

    @Test("Only a create request exposes a draft id")
    func onlyCreateExposesADraftId() {
        let draftId = UUID()
        #expect(ConnectionFormRequest.create(draftId: draftId).draftId == draftId)
        #expect(ConnectionFormRequest.edit(connectionId: UUID()).draftId == nil)
    }

    @Test("A request round trips through Codable")
    func requestRoundTripsThroughCodable() throws {
        let requests: [ConnectionFormRequest] = [
            .edit(connectionId: UUID()),
            .create(draftId: UUID())
        ]

        for request in requests {
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(ConnectionFormRequest.self, from: data)
            #expect(decoded == request)
        }
    }
}
