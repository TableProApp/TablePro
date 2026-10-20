import Foundation
@testable import TableProMobile
import TableProSQLGrammar
import Testing

@MainActor
struct CatalogChangeBoardTests {
    private let id = UUID()

    @Test("Kinds posted after a window's last look are combined")
    func kindsSinceCombine() {
        let board = CatalogChangeBoard()
        board.post(.tables, for: id)
        let seen = board.generation(for: id)
        board.post(.routines, for: id)
        board.post(.schemas, for: id)

        #expect(board.generation(for: id) == 3)
        #expect(board.kinds(for: id, since: seen) == [.routines, .schemas])
        #expect(board.kinds(for: id, since: 3).isEmpty)
    }

    @Test("A change with no kinds is not posted")
    func emptyIsIgnored() {
        let board = CatalogChangeBoard()
        board.post([], for: id)
        #expect(board.generation(for: id) == 0)
    }

    @Test("A window further behind than the kept changes reloads everything")
    func farBehindReloadsEverything() {
        let board = CatalogChangeBoard()
        for _ in 0 ..< 20 {
            board.post(.tables, for: id)
        }
        #expect(board.kinds(for: id, since: 0) == .everything)
        #expect(board.kinds(for: id, since: 19) == .tables)
    }

    @Test("Connections keep their own changes")
    func perConnection() {
        let board = CatalogChangeBoard()
        let other = UUID()
        board.post(.tables, for: other)
        #expect(board.generation(for: id) == 0)
        #expect(board.kinds(for: id, since: 0).isEmpty)
    }

    @Test("Temporary tables belong to the session that made them")
    func temporaryTablesPerSession() {
        let board = CatalogChangeBoard()
        let first = NSObject()
        let second = NSObject()
        board.noteSessionEffect(.init(temporaryTables: ["scratch"]), for: id, driver: ObjectIdentifier(first))
        board.noteSessionEffect(.init(temporaryTables: ["other"]), for: id, driver: ObjectIdentifier(first))

        #expect(board.temporaryTables(for: id, driver: ObjectIdentifier(first)) == ["scratch", "other"])
        #expect(board.temporaryTables(for: id, driver: ObjectIdentifier(second)).isEmpty)
        #expect(board.temporaryTables(for: id, driver: nil).isEmpty)
    }

    @Test("A USE leaves the session off the window's database until a switch, and a new session starts on it")
    func sessionLeftDatabase() {
        let board = CatalogChangeBoard()
        let first = NSObject()
        let second = NSObject()
        board.noteSessionEffect(.init(switchesDatabase: true), for: id, driver: ObjectIdentifier(first))

        #expect(board.sessionLeftDatabase(for: id, driver: ObjectIdentifier(first)))
        #expect(!board.sessionLeftDatabase(for: id, driver: ObjectIdentifier(second)))
        #expect(!board.sessionLeftDatabase(for: UUID(), driver: ObjectIdentifier(first)))
        board.noteSessionDatabaseSwitched(for: id)
        #expect(!board.sessionLeftDatabase(for: id, driver: ObjectIdentifier(first)))
    }
}
