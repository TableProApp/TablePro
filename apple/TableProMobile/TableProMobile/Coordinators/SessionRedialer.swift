import Foundation
import os
import TableProDatabase
import TableProModels

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
        prompter: (any ConnectionPrompter)?,
        joining: Bool = true
    ) async throws -> Outcome {
        while let inFlight = dials[connection.id] {
            if joining {
                return Outcome(session: try await inFlight.task.value, dialedHere: false)
            }
            // A database switch needs its own target, and a retry after a sign-in its new credentials.
            _ = try? await inFlight.task.value
        }
        let manager = connectionManager
        let dialId = UUID()
        let task = Task {
            // Delisted before any waiter resumes: awaiting a finished task never suspends, so a listed one would spin.
            defer {
                if dials[connection.id]?.id == dialId { dials[connection.id] = nil }
            }
            let session = try await manager.connect(connection, prompter: prompter)
            await Self.restore(schema, on: session.driver)
            return session
        }
        dials[connection.id] = Dial(id: dialId, task: task)
        return Outcome(session: try await task.value, dialedHere: true)
    }

    // Returns with no dial in flight, so a caller can tear the session down without cancelling one.
    func settled(_ connectionId: UUID) async {
        while let dial = dials[connectionId] {
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
