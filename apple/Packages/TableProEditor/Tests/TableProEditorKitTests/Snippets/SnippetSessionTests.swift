import Foundation
@testable import TableProEditorKit
import Testing

struct SnippetSessionTests {
    // "SELECT a FROM b": field 1 at 7..<8, field 2 at 14..<15, inserted at 10.
    private func session() throws -> SnippetSession {
        let snippet = EditorSnippet(
            text: "SELECT a FROM b",
            fields: [
                EditorSnippet.Field(ranges: [NSRange(location: 7, length: 1)]),
                EditorSnippet.Field(ranges: [NSRange(location: 14, length: 1)])
            ]
        )
        return try #require(SnippetSession(snippet: snippet, at: 10))
    }

    @Test("Ranges move to the insertion point and the final stop defaults to the end")
    func shiftsToInsertion() throws {
        let session = try session()

        #expect(session.fields.map { $0.ranges } == [[NSRange(location: 17, length: 1)], [NSRange(location: 24, length: 1)]])
        #expect(session.finalRange == NSRange(location: 25, length: 0))
        #expect(session.span == NSRange(location: 10, length: 15))
    }

    @Test("Typing over the active field resizes it and moves what follows")
    func typingOverActiveField() throws {
        var session = try session()

        let kept = session.apply(edit: NSRange(location: 17, length: 1), replacementLength: 5)
        #expect(kept)
        #expect(session.fields[0].ranges == [NSRange(location: 17, length: 5)])
        #expect(session.fields[1].ranges == [NSRange(location: 28, length: 1)])
        #expect(session.span == NSRange(location: 10, length: 19))
    }

    @Test("Typing at the edge of an empty active field grows it, not the next field")
    func edgeGrowsActiveOnly() throws {
        var session = try #require(SnippetSession(
            snippet: EditorSnippet(
                text: "",
                fields: [
                    EditorSnippet.Field(ranges: [NSRange(location: 0, length: 0)]),
                    EditorSnippet.Field(ranges: [NSRange(location: 0, length: 0)])
                ]
            ),
            at: 0
        ))

        let kept = session.apply(edit: NSRange(location: 0, length: 0), replacementLength: 2)
        #expect(kept)
        #expect(session.fields[0].ranges == [NSRange(location: 0, length: 2)])
        #expect(session.fields[1].ranges == [NSRange(location: 2, length: 0)])
    }

    @Test("Typing at the end of an active nested field grows the field around it too")
    func enclosingFieldGrowsWithChild() throws {
        let snippet = EditorSnippet(
            text: "abcx",
            fields: [
                EditorSnippet.Field(ranges: [NSRange(location: 0, length: 4)]),
                EditorSnippet.Field(ranges: [NSRange(location: 3, length: 1)])
            ]
        )
        var session = try #require(SnippetSession(snippet: snippet, at: 0))
        let moved = session.advance()
        #expect(moved)

        let replaced = session.apply(edit: NSRange(location: 3, length: 1), replacementLength: 1)
        let appended = session.apply(edit: NSRange(location: 4, length: 0), replacementLength: 1)

        #expect(replaced && appended)
        #expect(session.fields[0].ranges == [NSRange(location: 0, length: 5)])
        #expect(session.fields[1].ranges == [NSRange(location: 3, length: 2)])
    }

    @Test("Typing at the end of one copy that touches the next grows the first and moves the second")
    func adjacentCopies() throws {
        let snippet = EditorSnippet(
            text: "xx",
            fields: [EditorSnippet.Field(ranges: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])]
        )
        var session = try #require(SnippetSession(snippet: snippet, at: 0))

        let second = session.apply(edit: NSRange(location: 2, length: 0), replacementLength: 1)
        let first = session.apply(edit: NSRange(location: 1, length: 0), replacementLength: 1)

        #expect(second && first)
        #expect(session.fields[0].ranges == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    @Test("Undoing the expansion ends the session even when an empty field sits at its end")
    func undoingExpansionEnds() throws {
        let snippet = EditorSnippet(
            text: "SELECT ",
            fields: [EditorSnippet.Field(ranges: [NSRange(location: 7, length: 0)])]
        )
        var session = try #require(SnippetSession(snippet: snippet, at: 4))

        let kept = session.apply(edit: NSRange(location: 4, length: 7), replacementLength: 3)

        #expect(kept == false)
    }

    @Test("A field an edit swallows is dropped and Tab lands on the one after it")
    func swallowedFieldIsDropped() throws {
        let snippet = EditorSnippet(
            text: "SELECT * FROM t",
            fields: [
                EditorSnippet.Field(ranges: [NSRange(location: 7, length: 8)]),
                EditorSnippet.Field(ranges: [NSRange(location: 7, length: 1)]),
                EditorSnippet.Field(ranges: [NSRange(location: 14, length: 1)])
            ]
        )
        var session = try #require(SnippetSession(snippet: snippet, at: 0))
        let movedToSecond = session.advance()
        #expect(movedToSecond)

        let kept = session.apply(edit: NSRange(location: 7, length: 2), replacementLength: 1)
        #expect(kept)
        #expect(session.fields.count == 2)
        #expect(session.fields[0].ranges == [NSRange(location: 7, length: 7)])
        #expect(session.currentField == nil)
        let movedOn = session.advance()
        #expect(movedOn)
        #expect(session.currentField?.ranges == [NSRange(location: 13, length: 1)])
    }

    @Test("An edit crossing a field edge ends the session")
    func crossingEditEnds() throws {
        let snippet = EditorSnippet(text: "SELECT users", fields: [EditorSnippet.Field(ranges: [NSRange(location: 7, length: 5)])])
        var session = try #require(SnippetSession(snippet: snippet, at: 0))

        let kept = session.apply(edit: NSRange(location: 5, length: 4), replacementLength: 0)
        #expect(kept == false)
    }

    @Test("An edit that takes the whole snippet ends the session")
    func swallowedSpanEnds() throws {
        var session = try session()

        let kept = session.apply(edit: NSRange(location: 5, length: 30), replacementLength: 0)
        #expect(kept == false)
    }

    @Test("Advance stops after the last field, retreat stops at the first")
    func navigationBounds() throws {
        var session = try session()

        session.retreat()
        #expect(session.current == 0)
        let movedToSecond = session.advance()
        #expect(movedToSecond)
        let movedPastLast = session.advance()
        #expect(movedPastLast == false)
        #expect(session.current == 1)
    }

    @Test("A snippet with no fields starts no session")
    func noFieldsNoSession() {
        #expect(SnippetSession(snippet: EditorSnippet(text: "SELECT 1", fields: []), at: 0) == nil)
    }
}
