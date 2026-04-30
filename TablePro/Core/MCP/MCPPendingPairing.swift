import CryptoKit
import Foundation

enum MCPPairingPhase: Sendable, Equatable {
    case pending(expiresAt: Date)
    case approved
    case consumed
    case expired
}

actor MCPPendingPairing {
    let code: String
    let challenge: String
    let clientName: String
    let plaintextToken: String
    private(set) var phase: MCPPairingPhase

    init(
        code: String,
        challenge: String,
        clientName: String,
        plaintextToken: String,
        ttl: Duration
    ) {
        self.code = code
        self.challenge = challenge
        self.clientName = clientName
        self.plaintextToken = plaintextToken
        let expiresAt = Date.now.addingTimeInterval(Self.seconds(from: ttl))
        self.phase = .pending(expiresAt: expiresAt)
    }

    func consume(verifier: String, now: Date = .now) throws -> PairingExchangeRecord {
        switch phase {
        case .pending(let expiresAt):
            guard expiresAt > now else {
                phase = .expired
                throw MCPError.expired("pairing code")
            }
            let computed = Self.sha256Base64Url(of: verifier)
            guard Self.constantTimeEqual(challenge, computed) else {
                throw MCPError.forbidden("challenge mismatch")
            }
            phase = .consumed
            return PairingExchangeRecord(
                plaintextToken: plaintextToken,
                challenge: challenge,
                expiresAt: expiresAt
            )

        case .approved:
            throw MCPError.invalidRequest("pairing already approved but not yet consumed")

        case .consumed:
            throw MCPError.notFound("pairing code")

        case .expired:
            throw MCPError.expired("pairing code")
        }
    }

    func markExpired() {
        switch phase {
        case .pending:
            phase = .expired
        default:
            break
        }
    }

    func currentExpiresAt() -> Date? {
        if case .pending(let expiresAt) = phase { return expiresAt }
        return nil
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    static func sha256Base64Url(of value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let data = Data(digest)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var result: UInt8 = 0
        for index in 0..<lhsBytes.count {
            result |= lhsBytes[index] ^ rhsBytes[index]
        }
        return result == 0
    }
}

actor MCPPairingRegistry {
    private var pairings: [String: MCPPendingPairing] = [:]
    private var expirationTasks: [String: Task<Void, Never>] = [:]

    func add(_ pairing: MCPPendingPairing, ttl: Duration) {
        pairings[pairing.code] = pairing
        scheduleExpiration(for: pairing, ttl: ttl)
    }

    func get(code: String) -> MCPPendingPairing? {
        pairings[code]
    }

    func remove(code: String) {
        pairings.removeValue(forKey: code)
        expirationTasks[code]?.cancel()
        expirationTasks.removeValue(forKey: code)
    }

    func count() -> Int {
        pairings.count
    }

    private func scheduleExpiration(for pairing: MCPPendingPairing, ttl: Duration) {
        let code = pairing.code
        expirationTasks[code]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: ttl)
            guard !Task.isCancelled else { return }
            await pairing.markExpired()
            await self?.remove(code: code)
        }
        expirationTasks[code] = task
    }
}
