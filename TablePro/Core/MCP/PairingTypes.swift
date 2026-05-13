import Foundation

struct PairingRequest: Sendable, Equatable {
    let clientName: String
    let challenge: String
    let redirectURL: URL
    let requestedScopes: String?
    let requestedConnectionIds: Set<UUID>?
}

struct PairingExchange: Sendable, Equatable {
    let code: String
    let verifier: String
}
