import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct ImportStatementCountTests {
    private func script(statements: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("count-\(UUID().uuidString).sql")
        try Data(String(repeating: "SELECT 1;\n", count: statements).utf8).write(to: url)
        return url
    }

    @Test("A count reaches every statement in the file")
    func countsEveryStatement() async throws {
        let url = try script(statements: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try await ImportStatementCount.count(url, encoding: .utf8, grammar: TestGrammar.postgres)

        #expect(count == 1_000)
    }

    @Test("Cancelling the dialog's count stops the scan before the end of the file", .timeLimit(.minutes(1)))
    func cancelReachesTheScan() async throws {
        let total = 2_000_000
        let url = try script(statements: total)
        defer { try? FileManager.default.removeItem(at: url) }

        let counting = Task {
            try await ImportStatementCount.count(url, encoding: .utf8, grammar: TestGrammar.postgres)
        }
        counting.cancel()

        switch await counting.result {
        case .success(let count):
            #expect(count < total)
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
