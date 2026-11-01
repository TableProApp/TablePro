//
//  PostgreSQLPluginDriver+LiveMessages.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit

struct LibPQNotification: Sendable, Equatable {
    let channel: String
    let payload: String
}

// Redshift and CockroachDB are siblings of this class and never conform; PGlite turns it off through
// `canFollowNotifications`.
extension PostgreSQLPluginDriver: PluginLiveMessaging {
    var liveMessageKind: PluginLiveMessageKind? {
        canFollowNotifications ? .notifications : nil
    }

    func subscribe(
        _ request: PluginLiveSubscriptionRequest,
        sessions: any PluginLiveSessionSource
    ) async throws -> any PluginLiveSubscription {
        guard canFollowNotifications,
              let listener = try await sessions.openSession() as? PostgreSQLPluginDriver
        else { throw LibPQPluginError.notConnected }
        listener.core.interruptBlockedCallOnDisconnect()
        for statement in PostgreSQLListenStatements.listen(request.channels) {
            _ = try await listener.execute(query: statement)
        }
        return PostgreSQLLiveSubscription(listener: listener)
    }
}

enum PostgreSQLListenStatements {
    static let notifyStatement = "SELECT pg_catalog.pg_notify($1, $2)"

    // LISTEN takes an identifier, never a parameter, so each channel is quoted as one.
    static func listen(_ channels: [String]) -> [String] {
        channels.map { "LISTEN \(PostgreSQLObjectQueries.quoteIdentifier($0))" }
    }
}

final class PostgreSQLLiveSubscription: PluginLiveSubscription, @unchecked Sendable {
    // Short, so a NOTIFY sent on this session runs between two waits instead of behind a long one.
    private static let waitMicroseconds: Int64 = 250_000
    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "LiveMessages")

    let messages: AsyncThrowingStream<PluginLiveMessage, Error>
    private let listener: PostgreSQLPluginDriver
    private let reader: Task<Void, Never>

    init(listener: PostgreSQLPluginDriver) {
        self.listener = listener
        let (stream, continuation) = AsyncThrowingStream<PluginLiveMessage, Error>.makeStream()
        messages = stream
        reader = Task {
            do {
                while !Task.isCancelled {
                    let batch = try await listener.core.nextNotifications(waitMicroseconds: Self.waitMicroseconds)
                    let arrived = Date()
                    for notification in batch {
                        continuation.yield(PluginLiveMessage(
                            timestamp: arrived,
                            channel: notification.channel,
                            payload: notification.payload
                        ))
                    }
                }
                continuation.finish()
            } catch {
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                Self.logger.info("Notification read ended: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                continuation.finish(throwing: error)
            }
        }
    }

    func publish(_ payload: String, to channel: String) async throws {
        _ = try await listener.executeParameterized(
            query: PostgreSQLListenStatements.notifyStatement,
            parameters: [.text(channel), .text(payload)]
        )
    }

    func close() async {
        reader.cancel()
        _ = await reader.value
    }
}
