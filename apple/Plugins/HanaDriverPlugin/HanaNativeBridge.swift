import Foundation

protocol HanaNativeBridge: Sendable {
    func open(configuration: Data, interruption: HanaOpenInterruption) throws -> UInt64
    func connect(_ ticket: HanaOperationTicket) throws -> Data
    func execute(_ ticket: HanaOperationTicket, request: Data) throws -> Data
    func explain(_ ticket: HanaOperationTicket, request: Data) throws -> Data
    func openCursor(_ ticket: HanaOperationTicket, request: Data) throws -> Data
    func fetch(_ ticket: HanaOperationTicket) throws -> Data
    func closeCursor(_ ticket: HanaOperationTicket) throws -> Data
    func ping(_ ticket: HanaOperationTicket) throws
    func cancel(_ ticket: HanaOperationTicket)
    func close(session: UInt64)
}
