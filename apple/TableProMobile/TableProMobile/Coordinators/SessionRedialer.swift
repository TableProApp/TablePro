import Foundation
import os
import TableProDatabase
import TableProModels
import TableProSSHTransport

// Each scene has its own coordinator on the one shared session, so two windows coming back at once
// would each dial, and the later attempt cancels the earlier one's.
@MainActor
final class SessionRedialer {
    struct Outcome {
        let session: ConnectionSession
        let dialedHere: Bool
    }

    private struct Dial {
        let id: UUID
        let task: Task<ConnectionSession, any Error>
        let prompter: SharedDialPrompter
        var consumers: Set<ObjectIdentifier>
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SessionRedialer")

    private let connectionManager: ConnectionManager
    private var dials: [UUID: Dial] = [:]

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    // The schema goes back inside the dial, so a window that joins or adopts it never reads the default schema.
    func redial(
        _ connection: DatabaseConnection,
        schema: String?,
        prompter: ConnectionPromptQueue?,
        joining: Bool = true,
        consumer: AnyObject? = nil,
        stillWanted: @MainActor () -> Bool = { true }
    ) async throws -> Outcome {
        let consumerId = consumer.map(ObjectIdentifier.init)
        while let inFlight = dials[connection.id] {
            if joining {
                if let consumerId { dials[connection.id]?.consumers.insert(consumerId) }
                inFlight.prompter.add(consumerId, prompter)
                return Outcome(session: try await inFlight.task.value, dialedHere: false)
            }
            // A database switch needs its own target, and a retry after a sign-in its new credentials.
            _ = try? await inFlight.task.value
        }
        // A dial replaces the session other windows use, so a window that went away while it waited dials nothing.
        guard stillWanted(), !Task.isCancelled else { throw CancellationError() }
        let manager = connectionManager
        let dialId = UUID()
        let shared = SharedDialPrompter()
        shared.add(consumerId, prompter)
        let task = Task {
            // Delisted before any waiter resumes: awaiting a finished task never suspends, so a listed one would spin.
            defer {
                if dials[connection.id]?.id == dialId { dials[connection.id] = nil }
            }
            let session = try await manager.connect(connection, prompter: shared)
            await Self.restore(schema, on: session.driver)
            return session
        }
        dials[connection.id] = Dial(id: dialId, task: task, prompter: shared, consumers: consumerId.map { [$0] } ?? [])
        return Outcome(session: try await task.value, dialedHere: true)
    }

    // A window that goes away stops waiting; the dial is cancelled only when no other window still waits on it, so
    // a polled connect or SSH handshake stops. An abandoned dial is delisted at once, so a retry starts its own
    // rather than wait out a blocked connect.
    func leave(_ connectionId: UUID, consumer: AnyObject) -> Bool {
        guard var dial = dials[connectionId] else { return true }
        dial.consumers.remove(ObjectIdentifier(consumer))
        dial.prompter.remove(ObjectIdentifier(consumer))
        guard dial.consumers.isEmpty else {
            dials[connectionId] = dial
            return false
        }
        dials[connectionId] = nil
        dial.task.cancel()
        return true
    }

    // Returns with no dial in flight, so a caller can tear the session down without cancelling one. A window that
    // waits to take the dial's session is one of its consumers, so another window leaving does not cancel it.
    func settled(_ connectionId: UUID, consumer: AnyObject? = nil, prompter: ConnectionPromptQueue? = nil) async {
        let consumerId = consumer.map(ObjectIdentifier.init)
        while let dial = dials[connectionId] {
            if let consumerId {
                dials[connectionId]?.consumers.insert(consumerId)
                dial.prompter.add(consumerId, prompter)
            }
            _ = try? await dial.task.value
        }
    }

    private static func restore(_ schema: String?, on driver: any DatabaseDriver) async {
        guard let schema, let current = driver.currentSchema, current != schema else { return }
        do {
            try await driver.switchSchema(to: schema)
        } catch {
            logger.warning("Failed to restore schema \(schema, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// A shared dial asks its questions through a window still waiting on it. When the window asked goes away, its queue
// answers no and the question moves to the next window, so neither a host key question nor the dial is lost with it.
@MainActor
final class SharedDialPrompter: ConnectionPrompter {
    private var askers: [(id: ObjectIdentifier?, prompter: ConnectionPromptQueue)] = []

    func add(_ id: ObjectIdentifier?, _ prompter: ConnectionPromptQueue?) {
        guard let prompter, id == nil || !askers.contains(where: { $0.id == id }) else { return }
        askers.append((id, prompter))
    }

    func remove(_ id: ObjectIdentifier) {
        askers.removeAll { $0.id == id }
    }

    func confirm(_ question: ConnectionQuestion) async -> Bool {
        while let asker = askers.first(where: { !$0.prompter.hasNoScreen }) {
            if await asker.prompter.confirm(question) { return true }
            guard passedOn(by: asker) else { return false }
        }
        return false
    }

    // Each window joins a dial with its own prompt queue, and a queue takes typed answers.
    nonisolated var answersChallenges: Bool { true }

    func answer(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        while let asker = askers.first(where: { $0.prompter.answersChallenges && !$0.prompter.hasNoScreen }) {
            if let answers = await asker.prompter.answer(challenge) { return answers }
            guard passedOn(by: asker) else { return nil }
        }
        return nil
    }

    // A window whose screen closed answers no before it leaves the dial, and that no is nobody's answer. It stays
    // listed, so it is asked again once a screen shows its queue.
    private func passedOn(by asker: (id: ObjectIdentifier?, prompter: ConnectionPromptQueue)) -> Bool {
        if asker.prompter.hasNoScreen { return true }
        guard let id = asker.id else { return false }
        return !askers.contains { $0.id == id }
    }
}
