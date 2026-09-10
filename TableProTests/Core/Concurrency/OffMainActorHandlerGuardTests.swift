//
//  OffMainActorHandlerGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Off-main-actor callback isolation")
struct OffMainActorHandlerGuardTests {
    @Test("Every Dispatch source handler declares its own isolation")
    func dispatchSourceHandlersDeclareTheirIsolation() throws {
        let offenders = try Self.offenders(Self.dispatchHandlerOffenders)
        #expect(
            offenders.isEmpty,
            """
            Dispatch calls a source handler on the source's own queue, and DispatchSourceHandler is \
            not @Sendable, so a closure literal written inside a @MainActor type inherits an \
            isolation that queue cannot honour and the process traps before the body runs. Write \
            `{ @Sendable in ... }` and hop with `Task { @MainActor in ... }` or \
            `MainActor.assumeIsolated`: \(offenders.sorted())
            """
        )
    }

    @Test("Every FSEvents callback is declared where it cannot inherit an actor")
    func fsEventsCallbacksCannotInheritAnActor() throws {
        let offenders = try Self.offenders(Self.fsEventsOffenders)
        #expect(
            offenders.isEmpty,
            """
            An FSEvents callback runs on the stream's dispatch queue. Written inline inside a \
            @MainActor type it inherits main-actor isolation and traps there, so declare it as a \
            `nonisolated private static let` of type `FSEventStreamCallback` and pass that: \
            \(offenders.sorted())
            """
        )
    }

    private static let appSourceRoots = [
        "TablePro",
        "TableProMobile/TableProMobile",
        "Plugins",
        "Packages/TableProCore/Sources",
    ]

    private static let dispatchHandlerSetters = [
        "setEventHandler",
        "setCancelHandler",
        "setRegistrationHandler",
    ]

    private static func dispatchHandlerOffenders(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let line = lines[index]
            guard dispatchHandlerSetters.contains(where: line.contains), line.contains("{") else { return false }
            guard !line.contains("@Sendable") else { return false }
            return !nextNonEmptyLine(in: lines, after: index).hasPrefix("@Sendable")
        }
    }

    private static func fsEventsOffenders(in lines: [String]) -> [Int] {
        var offending: [Int] = []
        var argumentDepth = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let arguments = line.range(of: "FSEventStreamCreate(").map { String(line[$0.upperBound...]) }
            if argumentDepth > 0, trimmed.hasPrefix("{"), !trimmed.contains("@Sendable") {
                offending.append(index)
            } else if let arguments, arguments.contains("{"), !arguments.contains("@Sendable") {
                offending.append(index)
            }
            if declaresIsolatedCallback(lines, index) {
                offending.append(index)
            }
            guard argumentDepth > 0 || arguments != nil else { continue }
            argumentDepth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            argumentDepth = max(argumentDepth, 0)
        }
        return offending
    }

    private static func declaresIsolatedCallback(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        guard line.contains("FSEventStreamCallback"), line.contains("="), !line.contains("nonisolated") else {
            return false
        }
        return line.contains("= {") || nextNonEmptyLine(in: lines, after: index).hasPrefix("{")
    }

    private static func nextNonEmptyLine(in lines: [String], after index: Int) -> String {
        lines[(index + 1)...]
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func offenders(_ rule: ([String]) -> [Int]) throws -> [String] {
        let root = try repoRoot()
        var matches: [String] = []
        for relativePath in appSourceRoots {
            let sourceRoot = root.appendingPathComponent(relativePath)
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }

            for case let url as URL in enumerator
                where url.pathExtension == "swift" && !url.lastPathComponent.hasSuffix("Tests.swift") {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
                matches += rule(lines).map { "\(url.lastPathComponent):\($0 + 1)" }
            }
        }
        return matches
    }

    private static func repoRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("CLAUDE.md").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw HandlerGuardError.repoRootNotFound
    }

    private enum HandlerGuardError: Error {
        case repoRootNotFound
    }
}
