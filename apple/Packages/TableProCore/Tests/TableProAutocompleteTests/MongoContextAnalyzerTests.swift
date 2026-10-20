import Foundation
import TableProAutocomplete
import Testing

struct MongoContextAnalyzerTests {
    private func position(_ text: String) async -> MongoCompletionPosition {
        await MongoContextAnalyzer.analyze(text, cursor: text.utf16.count).position
    }

    @Test("A comment or string longer than any cut is read from the start of the text")
    func longSpansAreReadFromTheStart() async {
        let notes = String(repeating: "notes about the nightly load and its retries ", count: 140)

        #expect(await position("/*\n" + notes + "db.ord") == .suppressed)
        #expect(await position("// " + notes + "db.ord") == .suppressed)
        #expect(await position("/*\n" + notes + "it's done */\ndb.ord") == .databaseMember)
        #expect(await position("db.notes.insertOne({ body: \"it's " + notes + "\" });\ndb.ord") == .databaseMember)
    }
}
