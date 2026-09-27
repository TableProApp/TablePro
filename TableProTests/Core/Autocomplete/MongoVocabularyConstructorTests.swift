//
//  MongoVocabularyConstructorTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
@testable import TablePro
import Testing

/// Autocomplete offered `Int32`, `Long`, `Decimal128` and `BSONRegExp` while the shell defined none
/// of them, so accepting the suggestion ended the statement in a ReferenceError, and it never
/// offered `MinKey`, `Code` or the legacy UUID helpers the shell does define.
struct MongoVocabularyConstructorTests {
    private static let shellObjectTypes: Set<String> = ["Cursor", "DB", "DBCollection"]

    private func globalNames(of context: JSContext) -> Set<String> {
        let names = context.evaluateScript("Object.getOwnPropertyNames(this)")?.toArray() as? [String]
        return Set(names ?? [])
    }

    @Test("Autocomplete offers exactly the value constructors the shell defines")
    func offeredConstructorsAreTheShellsOwn() throws {
        let plain = try #require(JSContext())
        let shell = try MongoScriptContext.make(execute: { _ in #"{"ok":true,"v":"shop"}"# }, emit: { _ in true })

        let defined = globalNames(of: shell).subtracting(globalNames(of: plain)).filter { name in
            guard name.first?.isUppercase == true, !Self.shellObjectTypes.contains(name) else { return false }
            return shell.evaluateScript("typeof \(name)")?.toString() == "function"
        }
        let offered = Set(MongoVocabulary.bsonConstructors.map(\.name))

        #expect(defined.count > 20)
        #expect(offered == defined)
    }
}
