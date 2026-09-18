//
//  TaskCancellationShield.swift
//  TablePro
//

import Foundation

/// Runs work that has to finish whatever happens to the task awaiting it.
///
/// `Task.cancel()` reaches every child of a structured task, and a driver that installs a
/// `withTaskCancellationHandler` acts on it at once: measured in a swiftc probe, a `ROLLBACK`
/// issued inside an already-cancelled task fired its cancel handler before it was ever sent
/// (`["cancel request for ROLLBACK", "ROLLBACK sent", "ROLLBACK done"]` against the shielded
/// `["ROLLBACK sent", "ROLLBACK done"]`). An unstructured `Task` is not a child, so cancellation
/// stops at this boundary while priority and task-locals still carry through.
///
/// The standard library's `withTaskCancellationShield(operation:)` is macOS 27 and the deployment
/// target is 13, measured: "'withTaskCancellationShield(operation:)' is only available in macOS
/// 27.0 or newer".
///
/// Only a single `COMMIT` or `ROLLBACK` goes inside one of these. A statement loop in here would be
/// unstoppable.
internal enum TaskCancellationShield {
    internal static func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await work() }.value
    }
}
