import Foundation
@testable import TablePro
import Testing

struct ConnectionTagTokensTests {
    private let production = ConnectionTag(name: "production", color: .red)
    private let staging = ConnectionTag(name: "staging", color: .orange)

    @Test("A typed name matches its tag whatever the case")
    func matchesIgnoringCase() {
        let entries = ConnectionTagTokens.resolve(["Production", " staging "], among: [production, staging])
        #expect(entries == [.existing(production.id), .existing(staging.id)])
    }

    @Test("An unknown name becomes a new tag, stored lowercased")
    func unknownNameIsNew() {
        #expect(ConnectionTagTokens.resolve(["Analytics"], among: [production]) == [.new("analytics")])
    }

    @Test("Repeats and blanks drop, and the order stays as typed")
    func repeatsAndBlanksDrop() {
        let entries = ConnectionTagTokens.resolve(
            ["staging", "", "PRODUCTION", "Staging", "new", "new"],
            among: [production, staging]
        )
        #expect(entries == [.existing(staging.id), .existing(production.id), .new("new")])
    }
}
