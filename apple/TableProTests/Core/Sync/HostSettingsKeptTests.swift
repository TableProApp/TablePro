import Foundation
@testable import TablePro
import Testing

struct HostSettingsKeptTests {
    private func json(_ text: String) throws -> Any {
        try SettingsJSON.parse(Data(text.utf8))
    }

    private func text(_ value: Any?) throws -> String? {
        try value.map { String(decoding: try SettingsJSON.canonical($0), as: UTF8.self) }
    }

    @Test("An option a newer build added goes back as sent while this Mac's options are unchanged")
    func unknownOptionGoesBackAsSent() throws {
        var kept = HostSettingsKept()
        try kept.record(
            "editor", shape: .options,
            sent: try json(#"{"tabWidth":4,"newerOption":true}"#),
            held: try json(#"{"tabWidth":4}"#)
        )

        let reported = try kept.report("editor", local: try json(#"{"tabWidth":4}"#))

        #expect(try text(reported) == #"{"newerOption":true,"tabWidth":4}"#)
    }

    @Test("Editing another option keeps the kept one; editing the kept one ends it")
    func onlyAnEditOfTheOptionEndsIt() throws {
        var kept = HostSettingsKept()
        try kept.record(
            "general", shape: .options,
            sent: try json(#"{"language":"newer","queryTimeoutSeconds":30}"#),
            held: try json(#"{"language":"system","queryTimeoutSeconds":30}"#)
        )

        let otherEdit = try kept.report("general", local: try json(#"{"language":"system","queryTimeoutSeconds":60}"#))
        let ownEdit = try kept.report("general", local: try json(#"{"language":"en","queryTimeoutSeconds":60}"#))

        #expect(try text(otherEdit) == #"{"language":"newer","queryTimeoutSeconds":60}"#)
        #expect(try text(ownEdit) == #"{"language":"en","queryTimeoutSeconds":60}"#)
        #expect(kept.entries.isEmpty)
    }

    @Test("A layout cleared here takes its kept options with it, so the engine sees the deletion")
    func clearedLayoutDropsKeptOptions() throws {
        var kept = HostSettingsKept()
        let category = "columnLayout.A.db.public.users"
        try kept.record(
            category, shape: .options,
            sent: try json(#"{"columnWidths":{"id":40},"newerOption":1}"#),
            held: try json(#"{"columnWidths":{"id":40}}"#)
        )

        let reported = try kept.report(category, local: nil)

        #expect(reported == nil)
        #expect(kept.entries.isEmpty)
    }

    @Test("A document the store took as sent keeps nothing")
    func takenDocumentKeepsNothing() throws {
        var kept = HostSettingsKept()
        try kept.record("tabs", shape: .options, sent: try json(#"{"a":1}"#), held: try json(#"{"a":1}"#))
        try kept.record("theme.ocean", shape: .document, sent: try json(#"{"b":2}"#), held: try json(#"{"b":2}"#))

        #expect(kept.entries.isEmpty)
    }

    @Test("A boolean and a number are told apart")
    func booleanIsNotANumber() throws {
        var kept = HostSettingsKept()
        try kept.record("tabs", shape: .options, sent: try json(#"{"a":true}"#), held: try json(#"{"a":1}"#))

        let reported = try kept.report("tabs", local: try json(#"{"a":1}"#))

        #expect(try text(reported) == #"{"a":true}"#)
    }

    @Test("A theme this build cannot read goes back as sent until this Mac's copy changes")
    func unreadableThemeGoesBackUntilAnEdit() throws {
        var kept = HostSettingsKept()
        let sent = #"{"id":"ocean","schema":9}"#
        try kept.record("theme.ocean", shape: .document, sent: try json(sent), held: try json(#"{"id":"ocean","schema":1}"#))

        let unchanged = try kept.report("theme.ocean", local: try json(#"{"id":"ocean","schema":1}"#))
        let edited = try kept.report("theme.ocean", local: try json(#"{"id":"ocean","schema":1,"name":"Mine"}"#))

        #expect(try text(unchanged) == sent)
        #expect(try text(edited) == #"{"id":"ocean","name":"Mine","schema":1}"#)
        #expect(kept.entries.isEmpty)
    }

    @Test("A category no store holds goes back as sent, and goes once this Mac holds its own copy")
    func categoryWithNoStore() throws {
        var kept = HostSettingsKept()
        try kept.record("newerCategory", shape: .document, sent: try json(#"{"x":1}"#), held: nil)

        let alone = try kept.report("newerCategory", local: nil)
        let categoriesBefore = kept.categories
        let ownCopy = try kept.report("newerCategory", local: try json(#"{"x":2}"#))

        #expect(try text(alone) == #"{"x":1}"#)
        #expect(categoriesBefore == ["newerCategory"])
        #expect(try text(ownCopy) == #"{"x":2}"#)
        #expect(kept.categories.isEmpty)
    }

    @Test("A theme removed here after it was kept reads as removed")
    func removedThemeIsNotKept() throws {
        var kept = HostSettingsKept()
        try kept.record("theme.ocean", shape: .document, sent: try json(#"{"v":2}"#), held: try json(#"{"v":1}"#))

        let reported = try kept.report("theme.ocean", local: nil)

        #expect(reported == nil)
        #expect(kept.entries.isEmpty)
    }

    @Test("A member a newer build added to a slash command goes back, while a rename still goes up")
    func slashCommandMembers() throws {
        var kept = HostSettingsKept()
        try kept.record(
            "customSlashCommands", shape: .items,
            sent: try json(#"[{"id":"A","name":"sql","icon":"bolt"},{"id":"B","name":"sql"}]"#),
            held: try json(#"[{"id":"A","name":"sql"},{"id":"B","name":"sql-2"}]"#)
        )

        let reported = try kept.report(
            "customSlashCommands",
            local: try json(#"[{"id":"A","name":"sql"},{"id":"B","name":"sql-2"}]"#)
        )

        let afterDelete = try kept.report("customSlashCommands", local: try json(#"[{"id":"B","name":"sql-2"}]"#))

        #expect(try text(reported) == #"[{"icon":"bolt","id":"A","name":"sql"},{"id":"B","name":"sql-2"}]"#)
        #expect(try text(afterDelete) == #"[{"id":"B","name":"sql-2"}]"#)
        #expect(kept.entries.isEmpty)
    }

    @Test("What was kept survives encoding, as the file holds it")
    func roundTripsThroughCoding() throws {
        var kept = HostSettingsKept()
        try kept.record("editor", shape: .options, sent: try json(#"{"n":1}"#), held: nil)
        try kept.record("theme.x", shape: .document, sent: try json(#"{"v":1}"#), held: nil)
        try kept.record(
            "customSlashCommands", shape: .items,
            sent: try json(#"[{"id":"A","extra":1}]"#), held: try json(#"[{"id":"A"}]"#)
        )
        kept.triedBuild = "42"

        let decoded = try JSONDecoder().decode(HostSettingsKept.self, from: try JSONEncoder().encode(kept))

        #expect(decoded == kept)
    }
}
