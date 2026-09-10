import CommonCrypto
import CryptoKit
import Foundation

/// SASL over Kafka's own framing: SaslHandshake names the mechanism, then each SASL token
/// travels inside a SaslAuthenticate request rather than as a bare byte block on the socket.
///
/// SaslHandshake is declared `flexibleVersions: none` at both v0 and v1, unlike almost
/// everything around it, so its strings and arrays stay legacy-encoded even on a modern
/// broker. Encoding it compactly does not produce a parse error; it produces an
/// authentication failure that looks like a wrong password.
enum KafkaSASL {
    static func authenticate(
        mechanism: KafkaSASLMechanism,
        username: String,
        password: String,
        connection: KafkaConnection
    ) async throws {
        try await handshake(mechanism: mechanism, connection: connection)
        switch mechanism {
        case .plain:
            _ = try await exchange(token: KafkaScram.plainAuthToken(username: username, password: password), connection: connection)
        case .scramSHA256:
            try await scram(username: username, password: password, hash: .sha256, connection: connection)
        case .scramSHA512:
            try await scram(username: username, password: password, hash: .sha512, connection: connection)
        }
    }

    private static func handshake(mechanism: KafkaSASLMechanism, connection: KafkaConnection) async throws {
        let version = try await connection.negotiatedVersion(for: .saslHandshake)
        let request = KafkaRequest(api: .saslHandshake, version: version) { writer, _ in
            writer.legacyString(mechanism.wireName)
        }
        var body = try await connection.send(request)
        let errorCode = try body.int16()
        let enabled = try body.array(compact: false) { try $0.legacyString() }
        guard errorCode == KafkaErrorCode.none else {
            if enabled.isEmpty {
                throw KafkaError.authenticationFailed(KafkaErrorCode.describe(errorCode))
            }
            throw KafkaError.authenticationFailed(String(
                format: String(localized: "the broker does not offer %@, only %@"),
                mechanism.wireName,
                enabled.joined(separator: ", ")
            ))
        }
    }

    private static func exchange(token: Data, connection: KafkaConnection) async throws -> Data {
        let version = try await connection.negotiatedVersion(for: .saslAuthenticate)
        let flexible = KafkaApiKey.saslAuthenticate.isFlexible(version: version)
        let request = KafkaRequest(api: .saslAuthenticate, version: version) { writer, _ in
            if flexible {
                writer.nullableCompactBytes(token)
                writer.emptyTaggedFields()
            } else {
                writer.nullableLegacyBytes(token)
            }
        }
        var body = try await connection.send(request)
        let errorCode = try body.int16()
        let message = flexible ? try body.nullableCompactString() : try body.nullableLegacyString()
        guard errorCode == KafkaErrorCode.none else {
            throw KafkaError.authenticationFailed(message ?? KafkaErrorCode.describe(errorCode))
        }
        let response = flexible ? try body.nullableCompactBytes() : try body.nullableLegacyBytes()
        return response ?? Data()
    }


    /// RFC 5802 SCRAM, without channel binding (`n,,` / `biws`), which is what Kafka uses.
    private static func scram(
        username: String,
        password: String,
        hash: KafkaScram.ScramHash,
        connection: KafkaConnection
    ) async throws {
        let clientNonce = KafkaScram.makeClientNonce()
        let bareFirst = "n=\(KafkaScram.escapedUsername(username)),r=\(clientNonce)"
        let clientFirst = "n,,\(bareFirst)"

        let serverFirstData = try await exchange(token: Data(clientFirst.utf8), connection: connection)
        guard let serverFirst = String(data: serverFirstData, encoding: .utf8) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker's SCRAM challenge was not readable"))
        }
        let attributes = KafkaScram.parseAttributes(serverFirst)
        guard let serverNonce = attributes["r"],
              let saltEncoded = attributes["s"],
              let iterationsText = attributes["i"],
              let iterations = Int(iterationsText),
              let salt = Data(base64Encoded: saltEncoded) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker's SCRAM challenge was incomplete"))
        }
        guard KafkaScram.isValidServerNonce(serverNonce, clientNonce: clientNonce) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker echoed a nonce that does not match ours"))
        }
        // RFC 7677 sets the floor at 4096 and Kafka's own default is 4096. A broker naming a
        // lower cost is choosing how cheaply an intercepted proof can be brute-forced, so the
        // floor is enforced here rather than trusted.
        guard KafkaScram.isAcceptableIterationCount(iterations) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker asked for an unsafe iteration count"))
        }

        let salted = try KafkaScram.saltedPassword(password: password, salt: salt, iterations: iterations, hash: hash)
        let withoutProof = "c=biws,r=\(serverNonce)"
        let authMessage = Data("\(bareFirst),\(serverFirst),\(withoutProof)".utf8)
        let proof = KafkaScram.clientProof(saltedPassword: salted, authMessage: authMessage, hash: hash)
        let clientFinal = "\(withoutProof),p=\(proof.base64EncodedString())"

        let serverFinalData = try await exchange(token: Data(clientFinal.utf8), connection: connection)
        // Every path out of here throws. Returning on an unreadable reply would report the
        // session as authenticated while skipping the signature check below, which is the one
        // thing proving the peer knows the password.
        guard let serverFinal = String(data: serverFinalData, encoding: .utf8) else {
            throw KafkaError.authenticationFailed(
                String(localized: "the broker's SCRAM response was not readable")
            )
        }
        let finalAttributes = KafkaScram.parseAttributes(serverFinal)
        if let error = finalAttributes["e"] {
            throw KafkaError.authenticationFailed(error)
        }
        // Verifying the server signature is what stops a spoofed broker replaying a challenge.
        guard let verifierEncoded = finalAttributes["v"], let verifier = Data(base64Encoded: verifierEncoded) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker did not prove it knows the password"))
        }
        let expected = KafkaScram.serverSignature(saltedPassword: salted, authMessage: authMessage, hash: hash)
        guard KafkaScram.constantTimeEquals(verifier, expected) else {
            throw KafkaError.authenticationFailed(String(localized: "the broker's signature did not verify"))
        }
    }
}
