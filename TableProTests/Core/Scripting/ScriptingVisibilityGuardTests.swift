//
//  ScriptingVisibilityGuardTests.swift
//  TableProTests
//
//  A connection whose External Clients level is Blocked must be invisible to a script, and the only
//  thing making it so is that every entry point checks. `connections()` filters, so anything a
//  script reaches by resolving an element is safe by construction; `current tab` is not, because it
//  starts from the front window. This scans the source rather than the behaviour, because the
//  regression it guards is a missing call, and a behavioural test only fails once the call is
//  missing from the one path the test happened to pick.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Scripting visibility guard")
struct ScriptingVisibilityGuardTests {
    private static let snapshotSource: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("TablePro/Core/Scripting/ScriptingSnapshot.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Every function that takes a `connectionId` and reads live state for it. `connections()` is
    /// the filter itself and `isVisibleToScripts` is the check, so neither is listed.
    private static let gatedFunctions = [
        "tabs(forConnection connectionId: UUID)",
        "currentTab()",
        "query(ofTab tabId: UUID, connectionId: UUID)",
        "focus(tab tabId: UUID, connectionId: UUID)"
    ]

    private func body(ofFunctionDeclaredAs signature: String) throws -> String {
        let source = Self.snapshotSource
        #expect(!source.isEmpty, "ScriptingSnapshot.swift was not readable")
        let start = try #require(source.range(of: "func \(signature)"), "no function declared as '\(signature)'")

        var depth = 0
        var seenOpen = false
        var body = ""
        for character in source[start.upperBound...] {
            if character == "{" {
                depth += 1
                seenOpen = true
            }
            if seenOpen { body.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return body
    }

    @Test("Every path that reads a connection's live state checks that a script may see it")
    func everyEntryPointChecksVisibility() throws {
        for signature in Self.gatedFunctions {
            let body = try body(ofFunctionDeclaredAs: signature)
            #expect(
                body.contains("isVisibleToScripts"),
                "'\(signature)' reads a connection without checking isVisibleToScripts"
            )
        }
    }

    /// The reader is shared with the JSON serializer, so the check has to sit in front of it here
    /// rather than inside it.
    @Test("Reading a tab's rows checks visibility before it reaches the result reader")
    func resultReadingChecksVisibilityFirst() throws {
        let body = try body(ofFunctionDeclaredAs: "result(")
        let check = try #require(body.range(of: "isVisibleToScripts"))
        let read = try #require(body.range(of: "DisplayedResultReader.read"))
        #expect(check.lowerBound < read.lowerBound, "visibility is checked after the rows are read")
    }

    /// `ensureConnected` runs the connection's pre-connect shell script, so the routes that can
    /// cause a connect have to ask first, the same as every route a person takes.
    @Test("Every path that can cause a connect asks about the pre-connect script first")
    func connectPathsAskAboutThePreConnectScript() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            root.deleteLastPathComponent()
        }
        let paths = [
            "TablePro/Core/Scripting/ScriptQueryRunner.swift",
            "TablePro/Core/Scripting/Commands/ScriptConnectionCommands.swift"
        ]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(
                source.contains("ScriptConnectGate.authorizeConnect"),
                "\(path) can reach ensureConnected without asking about the pre-connect script"
            )
        }
    }

    @Test("Blocked is the only level that hides a connection from scripts")
    func blockedIsTheOnlyHiddenLevel() {
        let hidden = ExternalAccessLevel.allCases.filter { $0 == .blocked }
        #expect(hidden == [.blocked])
        #expect(ExternalAccessLevel.allCases.count == 3)
    }
}
