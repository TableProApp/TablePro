import Foundation

protocol HanaSession: AnyObject, Sendable {
    var hasLostConnection: Bool { get }

    func connect(_ configuration: HanaConnectConfiguration) async throws -> HanaConnectResult
    func disconnect()
    func ping() async throws
    func execute(
        sql: String,
        parameters: [HanaBridgeCell]?,
        rowCap: Int,
        cancellation: HanaOperationSlot
    ) async throws -> HanaResultEnvelope
    func explain(sql: String, cancellation: HanaOperationSlot) async throws -> HanaResultEnvelope
    func cancel(_ cancellation: HanaOperationSlot)
    func applyQueryTimeout(seconds: Int)
}
