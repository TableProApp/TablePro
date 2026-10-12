//
//  LoadableExtensionListTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct LoadableExtensionListTests {
    @Test("An empty or blank value is an empty list")
    func emptyValueDecodesToNothing() throws {
        #expect(try LoadableExtensionList.decode(nil).isEmpty)
        #expect(try LoadableExtensionList.decode("").isEmpty)
        #expect(try LoadableExtensionList.decode("  \n").isEmpty)
    }

    @Test("An empty list encodes to the empty string, which removes the key")
    func emptyListEncodesToEmptyString() {
        #expect(LoadableExtensionList.encode([]).isEmpty)
    }

    @Test("A list round-trips in order with and without entry points")
    func roundTripsInOrder() throws {
        let list = [
            LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib"),
            LoadableExtension(path: "~/Extensions/vec0.dylib", entryPoint: "sqlite3_vec_init")
        ]
        let encoded = LoadableExtensionList.encode(list)
        #expect(try LoadableExtensionList.decode(encoded) == list)
    }

    @Test("Encoding keeps slashes readable and omits a default entry point")
    func encodingIsReadable() {
        let encoded = LoadableExtensionList.encode([LoadableExtension(path: "/usr/local/lib/vec0.dylib")])
        #expect(encoded == #"[{"path":"/usr/local/lib/vec0.dylib"}]"#)
    }

    @Test("A value that is not a JSON list is refused, never read as empty")
    func malformedValueThrows() {
        #expect(throws: LoadableExtensionError.malformedList) {
            try LoadableExtensionList.decode("/opt/homebrew/lib/mod_spatialite.dylib")
        }
        #expect(throws: LoadableExtensionError.malformedList) {
            try LoadableExtensionList.decode(#"{"path":"/x.dylib"}"#)
        }
    }

    @Test("Whitespace is trimmed and a blank entry point means the default")
    func normalizesWhitespace() throws {
        let decoded = try LoadableExtensionList.decode(#"[{"path":"  /x/vec0.dylib ","entryPoint":"  "}]"#)
        #expect(decoded == [LoadableExtension(path: "/x/vec0.dylib")])
        #expect(decoded.first?.entryPoint == nil)
    }

    @Test("A tilde path expands against the home directory")
    func expandsTilde() {
        let item = LoadableExtension(path: "~/lib/vec0.dylib")
        #expect(item.expandedPath == NSHomeDirectory() + "/lib/vec0.dylib")
        #expect(item.fileName == "vec0.dylib")
    }

    @Test("The shared field declares the extension content in the advanced section")
    func fieldDeclaresContent() {
        let rule = FieldVisibilityRule(fieldId: "libsqlMode", values: ["local"])
        let field = ConnectionField.loadableExtensions(visibleWhen: rule)
        #expect(field.id == LoadableExtensionList.fieldId)
        #expect(field.content == .loadableExtensions)
        #expect(field.section == .advanced)
        #expect(field.fieldType == .text)
        #expect(field.visibleWhen == rule)
    }

    @Test("Field content survives encoding, and an older field without it reads as plain")
    func fieldContentCodable() throws {
        let field = ConnectionField.loadableExtensions()
        let decoded = try JSONDecoder().decode(ConnectionField.self, from: JSONEncoder().encode(field))
        #expect(decoded.content == .loadableExtensions)

        let older = #"{"id":"x","label":"X","fieldType":{"text":{}}}"#
        let plain = try JSONDecoder().decode(ConnectionField.self, from: Data(older.utf8))
        #expect(plain.content == .plain)
    }
}
