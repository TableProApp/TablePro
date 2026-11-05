//
//  ServerOutputCapture.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// A result that can carry what its statement printed on the server.
protocol CarriesServerOutput {
    var serverOutput: PluginServerOutput { get set }
}

extension QueryFetchResult: CarriesServerOutput {}
extension QueryResult: CarriesServerOutput {}

/// Reads what a statement the editor ran printed on the server, on the session that ran it.
///
/// The session hands its lines to whoever asks next, so they are read before the statement and discarded: what a
/// grid save, the toolbar Commit, an MCP or AI statement or a table read printed is never reported under this one.
/// The read after runs for a failed statement too, for the failure to report. A read that fails is logged and
/// reported as no output.
enum ServerOutputCapture {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ServerOutputCapture")

    static func running<Value: CarriesServerOutput>(
        on driver: DatabaseDriver,
        failureOutput: ServerOutputBox,
        _ statement: () async throws -> Value
    ) async throws -> Value {
        _ = await drain(driver)
        // A Stop that landed during the read must not let the statement go out after it.
        try Task.checkCancellation()
        do {
            var value = try await statement()
            value.serverOutput = await drain(driver)
            return value
        } catch {
            if !DatabaseCancellationDiagnosis.isCancellation(error) {
                failureOutput.store(await drain(driver))
            }
            throw error
        }
    }

    /// How much of a failed statement's output its error message carries. The message is laid out as text in the
    /// error banner and handed to Fix with AI whole, and a loop can print 10,000 lines of 32,767 bytes before it fails.
    static let failureLineLimit = 20
    static let failureLineLength = 500

    /// The message a failed statement reports, followed by the first lines it printed before it failed.
    static func failureMessage(_ message: String, output: PluginServerOutput) -> String {
        guard !output.isEmpty else { return message }
        var sections = [message, String(localized: "Output before the error:")]
        sections.append(contentsOf: output.lines.prefix(failureLineLimit).map(clipped))
        if output.lines.count > failureLineLimit || output.isTruncated {
            sections.append(String(
                format: String(localized: "Only the first %lld lines are shown."),
                Int64(failureLineLimit)
            ))
        }
        return sections.joined(separator: "\n")
    }

    private static func clipped(_ line: String) -> String {
        let text = line as NSString
        guard text.length > failureLineLength else { return line }
        return text.substring(to: failureLineLength) + "…"
    }

    static func drain(_ driver: DatabaseDriver) async -> PluginServerOutput {
        guard !Task.isCancelled else { return .none }
        do {
            return try await driver.fetchServerOutput()
        } catch {
            logger.warning("Server output could not be read: \(error.publicLogShape, privacy: .public) \(String(describing: error), privacy: .private)")
            return .none
        }
    }
}

extension PluginServerOutput {
    func appending(_ later: PluginServerOutput) -> PluginServerOutput {
        PluginServerOutput(lines: lines + later.lines, isTruncated: isTruncated || later.isTruncated)
    }
}

/// Carries a failed statement's output from the driver's session to the main-actor code that reports the failure.
final class ServerOutputBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: PluginServerOutput.none)

    var output: PluginServerOutput {
        state.withLock { $0 }
    }

    func store(_ output: PluginServerOutput) {
        state.withLock { $0 = output }
    }
}
