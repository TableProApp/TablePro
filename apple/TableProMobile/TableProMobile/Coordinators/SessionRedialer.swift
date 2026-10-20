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

    private static let logger = Logger(subsystem: "com.TablePro", category: "SessionRedialer")

    private let connectionManager: ConnectionManager
    private var dials: [UUID: Task<ConnectionSession, any Error>] = [:]

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    // The schema goes back inside the dial, so a window that joins or adopts it never reads the default schema.
    func redial(
        _ connection: DatabaseConnection,
        schema: String?,
        prompter: (any ConnectionPrompter)?
    ) async throws -> Outcome {
        if let inFlight = dials[connection.id] {
            return Outcome(session: try await inFlight.value, dialedHere: false)
        }
        let manager = connectionManager
        let dial = Task {
            let session = try await manager.connect(connection, prompter: prompter)
            await Self.restore(schema, on: session.driver)
            return session
        }
        dials[connection.id] = dial
        defer {
            if dials[connection.id] == dial { dials[connection.id] = nil }
        }
        return Outcome(session: try await dial.value, dialedHere: true)
    }

    func settled(_ connectionId: UUID) async {
        _ = try? await dials[connectionId]?.value
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
