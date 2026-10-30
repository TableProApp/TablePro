//
//  LibPQServerMessageSink.swift
//  PostgreSQLDriverPlugin
//

import CLibPQ
import Foundation

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

    /// Only ever called for a connection libpq still reports as `CONNECTION_OK`. A server before
    /// 9.6 sends no non-localized severity, so a `RAISE WARNING ... ERRCODE '08006'` on a healthy
    /// session reaches `receive` looking exactly like the real thing; a session that ended cannot
    /// be healthy, so the healthy case is the one that must not keep the message.
    func clearIfHealthy() {
        lock.withLock { sessionEnding = nil }
    }

    // The observer runs on the connection's queue while a statement reads its reply, so it must not call back
    // into the connection.
    func observeNotices(_ observer: (@Sendable (LibPQServerNotice) -> Void)?) {
        lock.withLock { noticeObserver = observer }
    }

    fileprivate func receive(_ result: OpaquePointer) {
        let message = PQresultErrorMessage(result).map {
            String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let received = LibPQPluginError(message: message) { field in
            PQresultErrorField(result, field).map { String(cString: $0) }
        }
        let severity = PQresultErrorField(result, Self.severityField).map { String(cString: $0) }
        let (forward, observer) = lock.withLock { () -> (PQnoticeReceiver?, (@Sendable (LibPQServerNotice) -> Void)?) in
            if LibPQServerMessage.endsSession(severity: severity, sqlState: received.sqlState) {
                sessionEnding = received
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
