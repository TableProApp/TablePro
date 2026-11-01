//
//  RedisPluginDriver+LiveMessages.swift
//  RedisDriverPlugin
//

import Foundation
import os
import TableProPluginKit

extension RedisPluginDriver: PluginLiveMessaging {
    var liveMessageKind: PluginLiveMessageKind? { .pubSub }

    func subscribe(
        _ request: PluginLiveSubscriptionRequest,
        sessions: any PluginLiveSessionSource
    ) async throws -> any PluginLiveSubscription {
        guard let subscriber = try await sessions.openSession() as? RedisPluginDriver,
              let connection = subscriber.pubSubConnection
        else { throw RedisPluginError.notConnected }
        for command in RedisLivePush.subscribeCommands(for: request) {
            try await connection.sendSubscription(command)
        }
        return RedisLiveSubscription(subscriber: connection, sessions: sessions)
    }
}

enum RedisLivePush {
    static func subscribeCommands(for request: PluginLiveSubscriptionRequest) -> [[Data]] {
        var commands: [[Data]] = []
        if !request.channels.isEmpty {
            commands.append([Data("SUBSCRIBE".utf8)] + request.channels.map { Data($0.utf8) })
        }
        if !request.patterns.isEmpty {
            commands.append([Data("PSUBSCRIBE".utf8)] + request.patterns.map { Data($0.utf8) })
        }
        return commands
    }

    // nil for a confirmation or anything else a subscribed connection answers that is not a message.
    static func message(from reply: RedisReply, receivedAt: Date) throws -> PluginLiveMessage? {
        if let error = reply.errorMessage {
            throw RedisPluginError(code: 0, message: error, refusedByServer: true)
        }
        guard let items = reply.arrayValue, let kind = items.first?.stringValue?.lowercased() else { return nil }
        switch (kind, items.count) {
        case ("message", 3):
            return PluginLiveMessage(
                timestamp: receivedAt,
                channel: items[1].displayText,
                payload: items[2].displayText
            )
        case ("pmessage", 4):
            return PluginLiveMessage(
                timestamp: receivedAt,
                channel: items[2].displayText,
                pattern: items[1].displayText,
                payload: items[3].displayText
            )
        default:
            return nil
        }
    }
}

final class RedisLiveSubscription: PluginLiveSubscription, @unchecked Sendable {
    private static let waitMilliseconds: Int32 = 250
    private static let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "LiveMessages")

    let messages: AsyncThrowingStream<PluginLiveMessage, Error>
    private let reader: Task<Void, Never>
    private let sessions: any PluginLiveSessionSource
    private let publisherLock = NSLock()
    // A subscribed connection refuses PUBLISH, so a test message goes out on a second session, opened on first use.
    private var publisher: RedisPluginConnection?

    init(subscriber: RedisPluginConnection, sessions: any PluginLiveSessionSource) {
        self.sessions = sessions
        let (stream, continuation) = AsyncThrowingStream<PluginLiveMessage, Error>.makeStream()
        messages = stream
        reader = Task {
            do {
                while !Task.isCancelled {
                    let replies = try await subscriber.nextPushReplies(waitMilliseconds: Self.waitMilliseconds)
                    let arrived = Date()
                    for reply in replies {
                        if let message = try RedisLivePush.message(from: reply, receivedAt: arrived) {
                            continuation.yield(message)
                        }
                    }
                }
                continuation.finish()
            } catch {
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                Self.logger.info("Subscription read ended: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
                continuation.finish(throwing: error)
            }
        }
    }

    func publish(_ payload: String, to channel: String) async throws {
        let connection = try await publishingConnection()
        let reply = try await connection.executeCommand(
            [Data("PUBLISH".utf8), Data(channel.utf8), Data(payload.utf8)],
            scope: .outsideBlock
        )
        if let error = reply.errorMessage {
            throw RedisPluginError(code: 0, message: error, refusedByServer: true)
        }
    }

    func close() async {
        reader.cancel()
        _ = await reader.value
    }

    private func publishingConnection() async throws -> RedisPluginConnection {
        if let publisher = publisherLock.withLock({ publisher }) { return publisher }
        guard let driver = try await sessions.openSession() as? RedisPluginDriver,
              let connection = driver.pubSubConnection
        else { throw RedisPluginError.notConnected }
        publisherLock.withLock { publisher = connection }
        return connection
    }
}
