//
//  AttachedDatabaseListTests.swift
//  TableProPluginKitTests
//

import Foundation
import TableProPluginKit
import Testing

struct AttachedDatabaseListTests {
    @Test("An empty or blank value is an empty list, and an empty list encodes to the empty string")
    func emptyValues() throws {
        #expect(try AttachedDatabaseList.decode(nil).isEmpty)
        #expect(try AttachedDatabaseList.decode("  ").isEmpty)
        #expect(AttachedDatabaseList.encode([]).isEmpty)
    }

    @Test("A list round-trips in order with readable slashes")
    func roundTrips() throws {
        let list = [
            AttachedDatabase(name: "auth", path: "/data/auth.db"),
            AttachedDatabase(name: "audit", path: "~/data/audit.db")
        ]
        let encoded = AttachedDatabaseList.encode(list)
        #expect(encoded.contains(#""path":"/data/auth.db""#))
        #expect(try AttachedDatabaseList.decode(encoded) == list)
    }

    @Test("A value that is not a JSON list is refused, never read as empty")
    func malformedValueThrows() {
        #expect(throws: AttachedDatabaseError.malformedList) {
            try AttachedDatabaseList.decode("/data/auth.db")
        }
    }

    @Test("Names and paths are trimmed, and a tilde path expands against the home directory")
    func normalizes() throws {
        let decoded = try AttachedDatabaseList.decode(#"[{"name":" auth ","path":" ~/auth.db "}]"#)
        #expect(decoded == [AttachedDatabase(name: "auth", path: "~/auth.db")])
        #expect(decoded[0].expandedPath == NSHomeDirectory() + "/auth.db")
    }

    @Test("A file is offered under its name without the extension")
    func defaultName() {
        #expect(AttachedDatabase.defaultName(forPath: "/data/auth.db") == "auth")
        #expect(AttachedDatabase.defaultName(forPath: "/data/archive.2024.sqlite") == "archive.2024")
        #expect(AttachedDatabase.defaultName(forPath: "/data/History") == "History")
    }

    @Test("A name already taken or reserved gets a number, compared without case")
    func uniqueName() {
        #expect(AttachedDatabaseList.uniqueName(forPath: "/a/auth.db", taken: []) == "auth")
        #expect(AttachedDatabaseList.uniqueName(forPath: "/a/auth.db", taken: ["AUTH"]) == "auth_2")
        #expect(AttachedDatabaseList.uniqueName(forPath: "/a/auth.db", taken: ["auth", "auth_2"]) == "auth_3")
        #expect(AttachedDatabaseList.uniqueName(forPath: "/a/main.db", taken: []) == "main_2")
        #expect(AttachedDatabaseList.uniqueName(forPath: "/a/Temp.sqlite", taken: []) == "Temp_2")
    }

    @Test("Validation names the first entry that cannot attach")
    func validation() throws {
        try AttachedDatabaseList.validate([AttachedDatabase(name: "auth", path: "/a/auth.db")])
        let reserved = AttachedDatabase(name: "Main", path: "/a/x.db")
        #expect(throws: AttachedDatabaseError.reservedName(reserved)) {
            try AttachedDatabaseList.validate([reserved])
        }
        let second = AttachedDatabase(name: "AUTH", path: "/b/auth.db")
        #expect(throws: AttachedDatabaseError.duplicateName(second)) {
            try AttachedDatabaseList.validate([AttachedDatabase(name: "auth", path: "/a/auth.db"), second])
        }
        let relative = AttachedDatabase(name: "auth", path: "data/auth.db")
        #expect(throws: AttachedDatabaseError.relativePath(relative)) {
            try AttachedDatabaseList.validate([relative])
        }
        let unnamed = AttachedDatabase(name: " ", path: "/a/auth.db")
        #expect(throws: AttachedDatabaseError.missingName(unnamed)) {
            try AttachedDatabaseList.validate([unnamed])
        }
    }

    @Test("A missing file is skipped and named, a failed attach is recorded, and the rest attach in order")
    func attacherSkipsAndContinues() async {
        let missing = AttachedDatabase(name: "gone", path: "/a/gone.db")
        let broken = AttachedDatabase(name: "broken", path: "/a/broken.db")
        let good = AttachedDatabase(name: "auth", path: "/a/auth.db")
        var attached: [String] = []
        let failures = await AttachedDatabaseAttacher.attach(
            [missing, broken, good],
            fileExists: { $0 != "/a/gone.db" },
            attach: { database in
                if database == broken { throw AttachTestError() }
                attached.append(database.name)
            }
        )
        #expect(attached == ["auth"])
        #expect(failures.map { $0.database } == [missing, broken])
        #expect(failures[0].reason.contains("/a/gone.db"))
        #expect(failures[1].reason == AttachTestError().localizedDescription)

        let warning = AttachedDatabaseAttacher.warning(for: failures)
        #expect(warning?.components(separatedBy: "\n").count == 2)
        #expect(warning?.contains("gone") == true)
        #expect(AttachedDatabaseAttacher.warning(for: []) == nil)
    }

    @Test("The shared field declares the attached database content in the advanced section")
    func fieldDeclaresContent() throws {
        let rule = FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
        let field = ConnectionField.attachedDatabases(visibleWhen: rule)
        #expect(field.id == AttachedDatabaseList.fieldId)
        #expect(field.content == .attachedDatabases)
        #expect(field.section == .advanced)
        #expect(field.visibleWhen == rule)
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: JSONEncoder().encode(field))
        #expect(decoded.content == .attachedDatabases)
    }
}

private struct AttachTestError: LocalizedError {
    var errorDescription: String? { "file is not a database" }
}
