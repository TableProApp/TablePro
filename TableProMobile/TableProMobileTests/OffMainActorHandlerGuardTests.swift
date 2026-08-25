import Foundation
import Testing

@Suite("Off-main-actor callback isolation")
struct OffMainActorHandlerGuardTests {
    @Test("Every Dispatch source handler declares its own isolation")
    func dispatchSourceHandlersDeclareTheirIsolation() throws {
        let offenders = try Self.offenders { lines in
            lines.indices.filter { index in
                let line = lines[index]
                guard Self.dispatchHandlerSetters.contains(where: line.contains), line.contains("{") else {
                    return false
                }
                guard !line.contains("@Sendable") else { return false }
                return !Self.nextNonEmptyLine(in: lines, after: index).hasPrefix("@Sendable")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Dispatch calls a source handler on the source's own queue, and DispatchSourceHandler is \
            not @Sendable, so a closure literal written inside a @MainActor type inherits an \
            isolation that queue cannot honour and the process traps before the body runs. Write \
            `{ @Sendable in ... }` and hop with `Task { @MainActor in ... }`: \(offenders.sorted())
            """
        )
    }

    private static let dispatchHandlerSetters = [
        "setEventHandler",
        "setCancelHandler",
        "setRegistrationHandler",
    ]

    private static func nextNonEmptyLine(in lines: [String], after index: Int) -> String {
        lines[(index + 1)...]
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func offenders(_ rule: ([String]) -> [Int]) throws -> [String] {
        let sourceRoot = try repoRoot().appendingPathComponent("TableProMobile/TableProMobile")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var matches: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            matches += rule(lines).map { "\(url.lastPathComponent):\($0 + 1)" }
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
