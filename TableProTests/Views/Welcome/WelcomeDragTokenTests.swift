//
//  WelcomeDragTokenTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@Suite("Welcome drag token")
struct WelcomeDragTokenTests {
    @Test("A saved connection row round-trips with its section")
    func connectionRoundTrip() throws {
        let id = UUID()
        let token = try #require(WelcomeDragToken.encode(.connection(id, section: .favorites)))
        #expect(WelcomeDragToken.decode(token) == .connection(id, section: .favorites))
    }

    @Test("A group row round-trips")
    func groupRoundTrip() throws {
        let id = UUID()
        let token = try #require(WelcomeDragToken.encode(.group(id)))
        #expect(WelcomeDragToken.decode(token) == .group(id))
    }

    @Test("Shared connections and section headers cannot be dragged")
    func notDraggable() {
        #expect(WelcomeDragToken.encode(.connection(UUID(), section: .linkedFolders)) == nil)
        #expect(WelcomeDragToken.encode(.connection(UUID(), section: .teamLibrary)) == nil)
        #expect(WelcomeDragToken.encode(.section(.favorites)) == nil)
    }

    @Test("A malformed or foreign token decodes to nothing")
    func rejectsGarbage() {
        #expect(WelcomeDragToken.decode("") == nil)
        #expect(WelcomeDragToken.decode("group|not-a-uuid") == nil)
        #expect(WelcomeDragToken.decode("connection|linkedFolders|\(UUID().uuidString)") == nil)
        #expect(WelcomeDragToken.decode("table|\(UUID().uuidString)") == nil)
    }
}
