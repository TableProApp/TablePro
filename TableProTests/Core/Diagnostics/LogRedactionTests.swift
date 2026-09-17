//
//  LogRedactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The text these tests feed in is the shape of a real PostgreSQL unique-violation message, which
/// carries the offending value. Nothing derived from an error may carry it into the system log.
@Suite("Log redaction")
struct LogRedactionTests {
    private static let serverText =
        "ERROR: duplicate key value violates unique constraint \"users_email_key\" Key (email)=(a@b.com) already exists."

    private enum DriverError: LocalizedError {
        case executionFailed(String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .executionFailed(let message): return message
            case .disconnected: return "The connection closed."
            }
        }
    }

    private struct BoxedError: Error {
        let serverText: String
    }

    private enum AppError: PubliclyLoggableError {
        case readOnlyConnection

        var publicLogDescription: String { "AppError.readOnlyConnection" }
    }

    @Test("An enum case's payload never reaches the public description")
    func enumPayloadIsDropped() {
        let shape = DriverError.executionFailed(Self.serverText).publicLogShape

        #expect(shape == "DriverError.executionFailed")
        #expect(!shape.contains("a@b.com"))
    }

    @Test("A case with no payload keeps its name, which is app vocabulary")
    func payloadlessCaseKeepsItsName() {
        #expect(DriverError.disconnected.publicLogShape == "DriverError.disconnected")
    }

    @Test("A struct error publishes its type and bridged code, not its stored text")
    func structErrorPublishesItsShape() {
        let shape = BoxedError(serverText: Self.serverText).publicLogShape

        #expect(!shape.contains("a@b.com"))
        #expect(shape.hasPrefix("BoxedError("))
    }

    @Test("An error that declares its description safe is published in full")
    func publiclyLoggableErrorIsPublishedInFull() {
        #expect(AppError.readOnlyConnection.publicLogShape == "AppError.readOnlyConnection")
    }

    @Test("A Foundation error keeps the domain and code a reader can act on")
    func foundationErrorKeepsDomainAndCode() {
        let shape = (NSError(domain: NSPOSIXErrorDomain, code: 61) as Error).publicLogShape

        #expect(shape.contains(NSPOSIXErrorDomain))
        #expect(shape.contains("61"))
    }

    @Test("A localizedDescription that embeds the server text is not what gets published")
    func localizedDescriptionIsNotThePublishedValue() {
        let error = DriverError.executionFailed(Self.serverText)

        #expect(error.localizedDescription.contains("a@b.com"))
        #expect(!error.publicLogShape.contains("a@b.com"))
    }

    /// Scoped to the app. A plugin cannot reach `publicLogShape`, which is internal to the app
    /// target, so the 16 sites under `Plugins/` need the helper in `TableProPluginKit` first, and
    /// that is an ABI event with its own version bump.
    @Test("No log call in the app publishes an error's description")
    func noCallSitePublishesErrorText() throws {
        let root = try repositoryRoot()
        let offenders = try publicErrorSites(under: root.appendingPathComponent("TablePro"), root: root)

        #expect(
            offenders.isEmpty,
            """
            These sites publish an error's text to the system log, where any local process and any \
            sysdiagnose can read it: \(offenders.sorted())
            """
        )
    }

    private func publicErrorSites(under directory: URL, root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard !url.path.contains("/.build/"), !url.path.contains("/checkouts/") else { continue }

            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated()
                where line.contains(".localizedDescription, privacy: .public") {
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                offenders.append("\(relative):\(index + 1)")
            }
        }

        return offenders
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw RedactionTestError.repositoryRootNotFound
    }

    private enum RedactionTestError: Error {
        case repositoryRootNotFound
    }
}
