import Foundation
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

private actor ReadLog {
    private(set) var tables: [String] = []

    func note(_ table: String) {
        tables.append(table)
    }
}

struct PluginNameSpellingsTests {
    @Test("Names repeated in one spelling pass, a name in two spellings throws")
    func twoSpellingsThrow() throws {
        try PluginNameSpellings.requireDistinctSpellings([composed, "t", composed, "t"])
        #expect(throws: PluginNameSpellingError.self) {
            try PluginNameSpellings.requireDistinctSpellings(["t", composed, decomposed])
        }
    }

    @Test("Rows naming one table in two spellings in the given column throw")
    func rowsInTwoSpellingsThrow() throws {
        let rows: [[PluginCellValue]] = [[.text(composed), "a"], [.text(composed), "b"], ["t", "c"]]
        try PluginNameSpellings.requireDistinctSpellings(in: rows, nameAt: 0)
        #expect(throws: PluginNameSpellingError.self) {
            try PluginNameSpellings.requireDistinctSpellings(in: rows + [[.text(decomposed), "d"]], nameAt: 0)
        }
    }

    @Test("A table-by-table read keys each table's answer and leaves out the empty ones")
    func readEachTableKeysEachAnswer() async throws {
        let log = ReadLog()
        let answer = try await PluginNameSpellings.readEachTable(["a", "b"]) { table -> [String] in
            await log.note(table)
            return table == "a" ? ["key"] : []
        }

        #expect(await log.tables == ["a", "b"])
        #expect(answer == ["a": ["key"]])
    }

    @Test("A table-by-table read over a listing that names one table in two spellings reads nothing")
    func readEachTableRefusesTwins() async throws {
        let log = ReadLog()
        await #expect(throws: PluginNameSpellingError.self) {
            try await PluginNameSpellings.readEachTable([composed, decomposed]) { table -> [String] in
                await log.note(table)
                return []
            }
        }
        #expect(await log.tables.isEmpty)
    }
}
