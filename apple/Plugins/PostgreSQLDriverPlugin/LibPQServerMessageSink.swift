//
//  LibPQServerMessageSink.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation
import TableProPluginKit

struct LibPQServerNotice: Sendable {
    let message: String
    let text: String
}

final class LibPQServerMessageSink: @unchecked Sendable {
    private static let severityField = Int32(UInt8(ascii: "V"))
    private static let primaryMessageField = Int32(UInt8(ascii: "M"))

    private let lock = NSLock()
    private var sessionEnding: LibPQPluginError?
    private var forwardedReceiver: PQnoticeReceiver?
    private var noticeObserver: (@Sendable (LibPQServerNotice) -> Void)?
    private var output = LibPQNoticeOutput()
    private var discardsOutput = false

    static func install(on connection: OpaquePointer) -> Unmanaged<LibPQServerMessageSink> {
        let retained = Unmanaged.passRetained(LibPQServerMessageSink())
        let previous = PQsetNoticeReceiver(connection, libpqServerMessageReceiver, retained.toOpaque())
        retained.takeUnretainedValue().lock.withLock {
            retained.takeUnretainedValue().forwardedReceiver = previous
        }
        return retained
    }

    var sessionEndingMessage: LibPQPluginError? {
        lock.withLock { sessionEnding }
    }

    // Before 9.6 the server sends no V field, so a healthy session's `RAISE WARNING ... ERRCODE '08006'` looks session-ending.
    func clearIfHealthy() {
        lock.withLock { sessionEnding = nil }
    }

    // The observer runs on the connection's queue while a statement reads its reply, so it must not call back
    // into the connection.
    func observeNotices(_ observer: (@Sendable (LibPQServerNotice) -> Void)?) {
        lock.withLock { noticeObserver = observer }
    }

    func takeOutput() -> PluginServerOutput {
        lock.withLock { output.take() }
    }

    func discardingOutput<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.withLock { discardsOutput = true }
        defer { lock.withLock { discardsOutput = false } }
        return try body()
    }

    fileprivate func receive(_ result: OpaquePointer) {
        let text = PQresultErrorMessage(result).map { String(cString: $0) } ?? ""
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let received = LibPQPluginError(message: message) { field in
            PQresultErrorField(result, field).map { String(cString: $0) }
        }
        let severity = PQresultErrorField(result, Self.severityField).map { String(cString: $0) }
        let isOutput = LibPQNoticeOutput.isOutput(severity: severity, sqlState: received.sqlState)
        let (forward, observer) = lock.withLock { () -> (PQnoticeReceiver?, (@Sendable (LibPQServerNotice) -> Void)?) in
            if LibPQServerMessage.endsSession(severity: severity, sqlState: received.sqlState) {
                sessionEnding = received
            }
            // The debugger shows what its observer gets, and nothing reads output from its target session.
            if isOutput, noticeObserver == nil, !discardsOutput {
                output.record(text)
            }
            return (forwardedReceiver, noticeObserver)
        }
        if let observer {
            let primary = PQresultErrorField(result, Self.primaryMessageField).map { String(cString: $0) }
            observer(LibPQServerNotice(message: primary ?? message, text: message))
        }
        forward?(nil, result)
    }
}

private func libpqServerMessageReceiver(_ context: UnsafeMutableRawPointer?, _ result: OpaquePointer?) {
    guard let context, let result else { return }
    Unmanaged<LibPQServerMessageSink>.fromOpaque(context).takeUnretainedValue().receive(result)
}
