import CryptoKit
import Foundation
import Testing

@testable import TablePro

/// SCRAM's cryptography and the two rules that decide whether a hostile broker can get past
/// it. The exchange itself needs a live connection, so what is pinned here is everything that
/// can be checked without one: the key derivation, and the guards that reject a broker.
@Suite("Kafka SASL")
struct KafkaSASLTests {
    // MARK: - Key derivation

    /// RFC 7677 §5's worked example. If the derivation is wrong, every SCRAM login fails
    /// against every broker, so this is the anchor for the whole mechanism.
    @Test("SCRAM-SHA-256 derives RFC 7677's published salted password")
    func rfc7677SaltedPassword() throws {
        let salt = Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ==")
        let derived = try KafkaScram.saltedPassword(
            password: "pencil",
            salt: #require(salt),
            iterations: 4_096,
            hash: .sha256
        )
        #expect(derived.base64EncodedString() == "xKSVEDI6tPlSysH6mUQZOeeOp01r6B3fcJbodRPcYV0=")
    }

    /// The client proof and the server signature come off that same salted password, and the
    /// server signature is what proves the peer knew the password.
    @Test("SCRAM-SHA-256 produces RFC 7677's client proof and server signature")
    func rfc7677ProofAndSignature() throws {
        let salt = try #require(Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ=="))
        let salted = try KafkaScram.saltedPassword(
            password: "pencil",
            salt: salt,
            iterations: 4_096,
            hash: .sha256
        )
        let authMessage = Data((
            "n=user,r=rOprNGfwEbeRWgbNEkqO,"
                + "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,"
                + "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
        ).utf8)

        let proof = KafkaScram.clientProof(saltedPassword: salted, authMessage: authMessage, hash: .sha256)
        #expect(proof.base64EncodedString() == "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")

        let signature = KafkaScram.serverSignature(saltedPassword: salted, authMessage: authMessage, hash: .sha256)
        #expect(signature.base64EncodedString() == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test("SHA-512 derives a 64-byte key, distinct from the SHA-256 one")
    func sha512DerivesItsOwnKey() throws {
        let salt = Data("salt".utf8)
        let sha256 = try KafkaScram.saltedPassword(password: "pencil", salt: salt, iterations: 4_096, hash: .sha256)
        let sha512 = try KafkaScram.saltedPassword(password: "pencil", salt: salt, iterations: 4_096, hash: .sha512)
        #expect(sha256.count == 32)
        #expect(sha512.count == 64)
    }

    // MARK: - What a hostile broker is not allowed to do

    /// RFC 7677 §4 sets the floor at 4096, and Kafka's own default is 4096. A broker naming a
    /// lower cost is choosing how cheaply an intercepted client proof can be brute-forced
    /// offline against a salt it also chose.
    @Test("An iteration count below 4096 is rejected")
    func lowIterationCountsAreRejected() {
        for iterations in [0, 1, 100, 4_095] {
            #expect(
                KafkaScram.isAcceptableIterationCount(iterations) == false,
                "i=\(iterations) should be refused"
            )
        }
        #expect(KafkaScram.isAcceptableIterationCount(4_096))
        #expect(KafkaScram.isAcceptableIterationCount(100_000))
        #expect(KafkaScram.isAcceptableIterationCount(1_000_001) == false)
    }

    /// A broker that does not echo the client's nonce is not answering this exchange, so
    /// accepting it would let a recorded challenge be replayed.
    @Test("A server nonce that does not extend the client's is rejected")
    func serverNonceMustExtendTheClientNonce() {
        #expect(KafkaScram.isValidServerNonce("abc123extra", clientNonce: "abc123"))
        #expect(KafkaScram.isValidServerNonce("abc123", clientNonce: "abc123") == false)
        #expect(KafkaScram.isValidServerNonce("xyzabc123", clientNonce: "abc123") == false)
        #expect(KafkaScram.isValidServerNonce("", clientNonce: "abc123") == false)
    }

    /// The nonce is the client's only contribution of freshness to the exchange.
    @Test("Client nonces are unique and free of SCRAM's delimiters")
    func clientNoncesAreUniqueAndSafe() {
        var seen = Set<String>()
        for _ in 0 ..< 200 {
            let nonce = KafkaScram.makeClientNonce()
            #expect(nonce.count >= 16)
            #expect(nonce.contains(",") == false)
            #expect(nonce.contains("=") == false)
            #expect(seen.contains(nonce) == false)
            seen.insert(nonce)
        }
    }

    // MARK: - Escaping

    /// RFC 5802's `saslname` escaping belongs to the username in the `n=` attribute, whose
    /// commas and equals signs would otherwise break SCRAM's framing. Applying it to the
    /// password derives a different key than the broker computed, so any password containing
    /// `,` or `=` would fail to authenticate.
    @Test("Only the username is saslname-escaped")
    func onlyTheUsernameIsEscaped() throws {
        #expect(KafkaScram.escapedUsername("plain") == "plain")
        #expect(KafkaScram.escapedUsername("a,b") == "a=2Cb")
        #expect(KafkaScram.escapedUsername("a=b") == "a=3Db")
        #expect(KafkaScram.escapedUsername("a=b,c") == "a=3Db=2Cc")

        // The password reaches PBKDF2 exactly as typed.
        let salt = Data("salt".utf8)
        let escaped = try KafkaScram.saltedPassword(password: "p=3Dw", salt: salt, iterations: 4_096, hash: .sha256)
        let literal = try KafkaScram.saltedPassword(password: "p=w", salt: salt, iterations: 4_096, hash: .sha256)
        #expect(escaped != literal)
    }

    // MARK: - PLAIN

    /// SASL PLAIN is authzid NUL authcid NUL password, and the leading empty authzid is
    /// required rather than optional.
    @Test("A PLAIN token is NUL-separated with an empty authzid")
    func plainTokenShape() {
        let token = KafkaScram.plainAuthToken(username: "user", password: "pencil")
        #expect([UInt8](token) == [0] + Array("user".utf8) + [0] + Array("pencil".utf8))
    }

    @Test("A PLAIN token carries a password containing separators unchanged")
    func plainTokenDoesNotEscape() {
        let token = KafkaScram.plainAuthToken(username: "u", password: "a,b=c")
        #expect([UInt8](token) == [0] + Array("u".utf8) + [0] + Array("a,b=c".utf8))
    }
}
