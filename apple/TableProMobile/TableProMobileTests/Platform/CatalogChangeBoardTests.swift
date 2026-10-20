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
}
