//
//  ConnectionTreeScopedIDTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionTreeScopedID")
struct ConnectionTreeScopedIDTests {
    @Test("A scoped id gives both halves back")
    func roundTrips() {
        let id = UUID()
        let scoped = ConnectionTreeScopedID.make(connectionId: id, inner: "db:shop|schema:public")
        #expect(ConnectionTreeScopedID.connectionId(of: scoped) == id)
        #expect(ConnectionTreeScopedID.inner(of: scoped) == "db:shop|schema:public")
    }

    @Test("A separator inside the node id splits nothing, because the split is by length")
    func innerMaySplitOnSeparator() {
        let id = UUID()
        let scoped = ConnectionTreeScopedID.make(connectionId: id, inner: "db:a/b/c")
        #expect(ConnectionTreeScopedID.connectionId(of: scoped) == id)
        #expect(ConnectionTreeScopedID.inner(of: scoped) == "db:a/b/c")
    }

    @Test("Two connections never collide on the same object name")
    func scopesAreDistinct() {
        let first = ConnectionTreeScopedID.make(connectionId: UUID(), inner: "schema:public")
        let second = ConnectionTreeScopedID.make(connectionId: UUID(), inner: "schema:public")
        #expect(first != second)
    }

    @Test("An empty node id is still a well formed scope")
    func emptyInner() {
        let id = UUID()
        let scoped = ConnectionTreeScopedID.make(connectionId: id, inner: "")
        #expect(ConnectionTreeScopedID.connectionId(of: scoped) == id)
        #expect(ConnectionTreeScopedID.inner(of: scoped) == "")
    }

    @Test("Anything that is not a scoped id is refused rather than half read")
    func refusesMalformed() {
        #expect(ConnectionTreeScopedID.connectionId(of: "") == nil)
        #expect(ConnectionTreeScopedID.connectionId(of: "conn-123") == nil)
        #expect(ConnectionTreeScopedID.connectionId(of: UUID().uuidString) == nil)
        #expect(ConnectionTreeScopedID.inner(of: "conn-123") == nil)
    }

    @Test("A prefix the right length that is not a UUID is refused too")
    func refusesNonUuidPrefix() {
        let scoped = String(repeating: "x", count: 36) + "/schema:public"
        #expect(ConnectionTreeScopedID.connectionId(of: scoped) == nil)
    }

    @Test("A wrong separator at the boundary is refused")
    func refusesWrongSeparator() {
        let scoped = "\(UUID().uuidString)|schema:public"
        #expect(ConnectionTreeScopedID.connectionId(of: scoped) == nil)
    }
}
