//
//  ScriptConnectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ScriptConnectionTests {
    private func listing(
        color: ConnectionColor = .none,
        group: ExternalConnectionListing.Group? = nil,
        tags: [ExternalConnectionListing.Tag] = []
    ) -> ExternalConnectionListing {
        ExternalConnectionListing(
            id: UUID(),
            name: "Acme prod",
            databaseType: "PostgreSQL",
            host: "db.acme.io",
            port: 5_432,
            username: "app_ro",
            database: "app",
            schema: "public",
            isConnected: true,
            color: color,
            group: group,
            tags: tags,
            aiPolicy: .never,
            externalAccess: .readWrite,
            safeModeLevel: .alert
        )
    }

    /// Cocoa reads every property through KVC, so that is what is checked.
    private func value(_ key: String, of connection: ScriptConnection) -> Any? {
        connection.value(forKey: key)
    }

    @Test("The existing properties come from the listing")
    func existingProperties() {
        let source = listing()
        let connection = ScriptConnection(listing: source)

        #expect(value("uniqueId", of: connection) as? String == source.id.uuidString)
        #expect(value("name", of: connection) as? String == "Acme prod")
        #expect(value("databaseType", of: connection) as? String == "PostgreSQL")
        #expect(value("host", of: connection) as? String == "db.acme.io")
        #expect(value("port", of: connection) as? Int == 5_432)
        #expect(value("currentDatabase", of: connection) as? String == "app")
        #expect(value("currentSchema", of: connection) as? String == "public")
        #expect(value("isConnected", of: connection) as? Bool == true)
        #expect(connection.safeMode == ScriptEnumerations.code(for: SafeModeLevel.alert))
        #expect(connection.externalAccess == ScriptEnumerations.code(for: ExternalAccessLevel.readWrite))
    }

    @Test("Color, group path, group color and tags come from the listing")
    func newProperties() {
        let group = ExternalConnectionListing.Group(id: UUID(), name: "Acme", path: ["Clients", "Acme"], color: .blue)
        let tags = [
            ExternalConnectionListing.Tag(id: UUID(), name: "production", color: .red),
            ExternalConnectionListing.Tag(id: UUID(), name: "reporting", color: .none)
        ]
        let connection = ScriptConnection(listing: listing(color: .orange, group: group, tags: tags))

        #expect((value("color", of: connection) as? NSNumber)?.uint32Value == ScriptEnumerations.fourCharCode("TPc2"))
        #expect(value("groupPath", of: connection) as? [String] == ["Clients", "Acme"])
        #expect((value("groupColor", of: connection) as? NSNumber)?.uint32Value == ScriptEnumerations.fourCharCode("TPc5"))
        #expect(value("tagNames", of: connection) as? [String] == ["production", "reporting"])
    }

    @Test("No color, no group and no tags read as none and empty lists")
    func emptyProperties() {
        let connection = ScriptConnection(listing: listing())
        let none = ScriptEnumerations.fourCharCode("TPc0")

        #expect((value("color", of: connection) as? NSNumber)?.uint32Value == none)
        #expect((value("groupPath", of: connection) as? [String])?.isEmpty == true)
        #expect((value("groupColor", of: connection) as? NSNumber)?.uint32Value == none)
        #expect((value("tagNames", of: connection) as? [String])?.isEmpty == true)
    }

    @Test("The listing's user name never reaches AppleScript")
    func userNameStaysOut() {
        let connection = ScriptConnection(listing: listing())

        for key in ["userName", "username", "user"] {
            #expect(!connection.responds(to: NSSelectorFromString(key)), "\(key) is scriptable")
        }
    }

    @Test("Every color has its own enumerator code")
    func colorCodesAreDistinct() {
        let codes = ConnectionColor.allCases.map { ScriptEnumerations.code(for: $0) }
        #expect(Set(codes).count == ConnectionColor.allCases.count)
    }
}
