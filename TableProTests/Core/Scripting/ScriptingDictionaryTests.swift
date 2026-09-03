//
//  ScriptingDictionaryTests.swift
//  TableProTests
//
//  Cocoa Scripting fails silently in every way that matters. A `cocoa class` naming a class that is
//  not in the binary, a `cocoa key` that no property answers, a terminology name bound to two codes,
//  or a command result declared as a type Cocoa cannot coerce all produce a dictionary that loads,
//  compiles in Script Editor, and then returns nothing or `errAEEventNotHandled` with no diagnostic
//  anywhere. Every rule below stands for one of those, measured against a throwaway scriptable app.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Scripting dictionary")
struct ScriptingDictionaryTests {
    // MARK: - Loading

    private static let bundleURL = Bundle(for: AppDelegate.self).bundleURL

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.bundleURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private func dictionary() throws -> XMLElement {
        let name = try #require(try infoPlist()["OSAScriptingDefinition"] as? String)
        let url = Self.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        let document = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
        return try #require(document.rootElement())
    }

    private func suite() throws -> XMLElement {
        let suites = try dictionary().elements(forName: "suite")
        return try #require(suites.first { $0.attribute(forName: "name")?.stringValue == "TablePro Suite" })
    }

    private func attribute(_ name: String, of element: XMLNode) -> String? {
        (element as? XMLElement)?.attribute(forName: name)?.stringValue
    }

    /// The key Cocoa derives from a property name when the sdef does not spell one out: the words
    /// run together, the first lowercased and the rest capitalized.
    private func derivedKey(fromName name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        guard let first = words.first else { return name }
        return ([first] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
    }

    private func cocoaKey(of property: XMLElement) -> String {
        if let explicit = property.elements(forName: "cocoa").first?.attribute(forName: "key")?.stringValue {
            return explicit
        }
        return derivedKey(fromName: property.attribute(forName: "name")?.stringValue ?? "")
    }

    // MARK: - The bundle claims to be scriptable

    @Test("The bundle declares scripting and ships the dictionary it names")
    func bundleDeclaresScripting() throws {
        let plist = try infoPlist()
        #expect(plist["NSAppleScriptEnabled"] as? Bool == true)

        let name = try #require(plist["OSAScriptingDefinition"] as? String)
        let url = Self.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The Standard Suite is included, so the app answers activate, quit, count and exists")
    func includesStandardSuite() throws {
        let includes = try dictionary().elements(forName: "xi:include")
        let hrefs = includes.compactMap { $0.attribute(forName: "href")?.stringValue }
        #expect(hrefs.contains { $0.hasSuffix("CocoaStandard.sdef") })
    }

    /// Redeclaring `application` rather than extending it is what `sdp` warns about, and it leaves
    /// the app with two `application` classes whose properties do not merge.
    @Test("The application class is extended, not redeclared")
    func extendsApplicationRatherThanRedeclaring() throws {
        let classes = try suite().elements(forName: "class")
        #expect(!classes.contains { $0.attribute(forName: "name")?.stringValue == "application" })
        #expect(try suite().elements(forName: "class-extension").count == 1)
    }

    // MARK: - Everything the dictionary names has to exist

    @Test("Every cocoa class in the dictionary is in the binary")
    func everyCocoaClassResolves() throws {
        let suite = try suite()
        var named: [String] = []
        for kind in ["class", "command"] {
            for element in suite.elements(forName: kind) {
                guard let cocoa = element.elements(forName: "cocoa").first,
                      let className = cocoa.attribute(forName: "class")?.stringValue
                else {
                    continue
                }
                named.append(className)
            }
        }

        #expect(!named.isEmpty)
        for className in named {
            #expect(
                NSClassFromString(className) is NSObject.Type,
                "\(className) is named by the sdef but not in the binary"
            )
        }
    }

    @Test("Every class property and element resolves to something its class answers")
    func everyCocoaKeyResolves() throws {
        for classElement in try suite().elements(forName: "class") {
            let className = try #require(classElement.elements(forName: "cocoa").first?
                .attribute(forName: "class")?.stringValue)
            let type = try #require(NSClassFromString(className) as? NSObject.Type)

            for property in classElement.elements(forName: "property") {
                let key = cocoaKey(of: property)
                #expect(
                    type.instancesRespond(to: Selector(key)),
                    "\(className) does not answer '\(key)'"
                )
            }
            for element in classElement.elements(forName: "element") {
                let key = try #require(element.elements(forName: "cocoa").first?
                    .attribute(forName: "key")?.stringValue)
                #expect(
                    type.instancesRespond(to: Selector(key)),
                    "\(className) does not answer element key '\(key)'"
                )
            }
            for respondsTo in classElement.elements(forName: "responds-to") {
                let method = try #require(respondsTo.elements(forName: "cocoa").first?
                    .attribute(forName: "method")?.stringValue)
                #expect(
                    type.instancesRespond(to: Selector(method)),
                    "\(className) does not implement '\(method)'"
                )
            }
        }
    }

    @Test("The application extension's keys resolve on NSApplication")
    func applicationExtensionKeysResolve() throws {
        let extensionElement = try #require(try suite().elements(forName: "class-extension").first)
        var keys: [String] = []
        for element in extensionElement.elements(forName: "element") {
            keys.append(contentsOf: element.elements(forName: "cocoa").compactMap {
                $0.attribute(forName: "key")?.stringValue
            })
        }
        for property in extensionElement.elements(forName: "property") {
            keys.append(cocoaKey(of: property))
        }

        #expect(keys.contains(ScriptingKeys.Element.connections))
        for key in keys {
            #expect(NSApplication.instancesRespond(to: Selector(key)), "NSApplication does not answer '\(key)'")
        }
    }

    // MARK: - Terminology has to be unambiguous

    /// Measured: two record properties both named `columns` under different codes made
    /// `columns of x` resolve to the wrong code and come back empty, with no error anywhere.
    @Test("No terminology name is bound to two different codes")
    func everyNameHasOneCode() throws {
        var codesByName: [String: Set<String>] = [:]

        func collect(_ element: XMLElement) {
            if let name = element.attribute(forName: "name")?.stringValue,
               let code = element.attribute(forName: "code")?.stringValue {
                codesByName[name, default: []].insert(code)
            }
            for child in element.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                collect(child)
            }
        }
        collect(try suite())

        let ambiguous = codesByName.filter { $0.value.count > 1 }
        #expect(ambiguous.isEmpty, "these names carry more than one code: \(ambiguous)")
    }

    @Test("Every code is four characters, and every command code is eight")
    func codesAreWellFormed() throws {
        func check(_ element: XMLElement, isCommand: Bool) {
            if let code = element.attribute(forName: "code")?.stringValue {
                #expect(code.utf8.count == (isCommand ? 8 : 4), "'\(code)' is the wrong length")
            }
            for child in element.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                check(child, isCommand: false)
            }
        }
        for command in try suite().elements(forName: "command") {
            #expect((command.attribute(forName: "code")?.stringValue?.utf8.count ?? 0) == 8)
            for child in command.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                check(child, isCommand: false)
            }
        }
        for kind in ["class", "class-extension", "record-type", "enumeration"] {
            for element in try suite().elements(forName: kind) {
                check(element, isCommand: false)
            }
        }
    }

    // MARK: - Results have to be shapes Cocoa can actually carry

    /// Measured against a throwaway scriptable app: a command whose `<result>` is `any`, `item` or
    /// `list` either fails with `errAEEventNotHandled` or drops the value entirely, and no
    /// declaration at all drops it silently. Only a scalar, a homogeneous list of a scalar, a
    /// declared class or a declared record-type survives the trip.
    @Test("Every command declares a result Cocoa can coerce")
    func commandResultsAreCoercible() throws {
        let suite = try suite()
        let declared = Set(
            (suite.elements(forName: "class") + suite.elements(forName: "record-type"))
                .compactMap { $0.attribute(forName: "name")?.stringValue }
        )
        let scalars: Set<String> = ["text", "integer", "real", "boolean", "date", "file", "specifier"]
        let uncoercible: Set<String> = ["any", "item", "list"]

        for command in suite.elements(forName: "command") {
            let name = command.attribute(forName: "name")?.stringValue ?? "?"
            let result = try #require(
                command.elements(forName: "result").first,
                "command '\(name)' declares no result, so its return value is discarded"
            )
            let type = attribute("type", of: result)
                ?? result.elements(forName: "type").first?.attribute(forName: "type")?.stringValue
            let resolved = try #require(type, "command '\(name)' has an untyped result")
            #expect(!uncoercible.contains(resolved), "command '\(name)' returns '\(resolved)', which never arrives")
            #expect(
                scalars.contains(resolved) || declared.contains(resolved),
                "command '\(name)' returns '\(resolved)', which is neither a scalar nor a declared type"
            )
        }
    }

    /// A record property holding a plain nested list cannot be built either, which is the whole
    /// reason rows are a list of `result row` records rather than a list of lists.
    @Test("No record property is a bare nested list")
    func recordPropertiesAvoidNestedLists() throws {
        let suite = try suite()
        let recordNames = Set(
            suite.elements(forName: "record-type").compactMap { $0.attribute(forName: "name")?.stringValue }
        )
        for record in suite.elements(forName: "record-type") {
            for property in record.elements(forName: "property") {
                guard let typeElement = property.elements(forName: "type").first,
                      typeElement.attribute(forName: "list")?.stringValue == "yes",
                      let type = typeElement.attribute(forName: "type")?.stringValue
                else {
                    continue
                }
                #expect(
                    type == "text" || type == "integer" || type == "real" || type == "boolean"
                        || recordNames.contains(type),
                    "'\(type)' as a list inside a record does not survive the Apple event"
                )
            }
        }
    }

    // MARK: - The encoder and the dictionary agree

    @Test("Every record key the encoder writes is declared in the dictionary")
    func encoderKeysAreDeclared() throws {
        var declared: Set<String> = []
        for record in try suite().elements(forName: "record-type") {
            for property in record.elements(forName: "property") {
                declared.insert(cocoaKey(of: property))
            }
        }

        for key in ScriptingKeys.QueryResult.all + ScriptingKeys.ResultRow.all {
            #expect(declared.contains(key), "'\(key)' is written by the encoder but not declared")
        }
    }

    @Test("Every command parameter key the commands read is declared in the dictionary")
    func parameterKeysAreDeclared() throws {
        var declared: Set<String> = []
        for command in try suite().elements(forName: "command") {
            for parameter in command.elements(forName: "parameter") {
                declared.insert(cocoaKey(of: parameter))
            }
        }

        let used = [
            ScriptingKeys.Parameter.connection,
            ScriptingKeys.Parameter.database,
            ScriptingKeys.Parameter.schema,
            ScriptingKeys.Parameter.rowLimit,
            ScriptingKeys.Parameter.timeout
        ]
        for key in used {
            #expect(declared.contains(key), "'\(key)' is read by a command but not declared")
        }
    }

    // MARK: - Enumerations

    @Test("Every enumerator code the app produces is declared in the dictionary")
    func enumeratorCodesAreDeclared() throws {
        var declared: Set<FourCharCode> = []
        for enumeration in try suite().elements(forName: "enumeration") {
            for enumerator in enumeration.elements(forName: "enumerator") {
                guard let code = enumerator.attribute(forName: "code")?.stringValue else { continue }
                declared.insert(ScriptEnumerations.fourCharCode(code))
            }
        }

        for level in SafeModeLevel.allCases {
            #expect(declared.contains(ScriptEnumerations.code(for: level)), "no enumerator for \(level)")
        }
        for access in ExternalAccessLevel.allCases {
            #expect(declared.contains(ScriptEnumerations.code(for: access)), "no enumerator for \(access)")
        }
        for kind in [
            TabType.query, .table, .createTable, .erDiagram,
            .serverDashboard, .usersRoles, .insights, .objectSource
        ] {
            #expect(declared.contains(ScriptEnumerations.code(for: kind)), "no enumerator for \(kind)")
        }
    }

    // MARK: - Nothing secret is reachable

    /// The one rule worth a test of its own. Granting another app Automation access to TablePro must
    /// not hand it the credentials TablePro holds, and the only thing standing between the two is
    /// which properties this class declares.
    @Test("A connection exposes no credential")
    func connectionExposesNoCredential() throws {
        let connectionClass = try #require(
            try suite().elements(forName: "class")
                .first { $0.attribute(forName: "name")?.stringValue == "connection" }
        )
        let keys = connectionClass.elements(forName: "property").map { cocoaKey(of: $0) }
        let names = connectionClass.elements(forName: "property")
            .compactMap { $0.attribute(forName: "name")?.stringValue }

        let forbidden = ["password", "secret", "token", "passphrase", "privateKey", "credential", "key"]
        for spelling in keys + names {
            let lowered = spelling.lowercased()
            for word in forbidden {
                #expect(!lowered.contains(word.lowercased()), "'\(spelling)' looks like a credential")
            }
        }
    }
}
