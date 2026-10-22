import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHNegotiationFailureTests {
    @Test("No agreed key exchange is the key exchange or host key stage, whatever else is missing")
    func noKeyExchange() {
        #expect(SSHNegotiationFailure.stage(kex: nil, cipher: nil, mac: nil) == .keyExchangeOrHostKey)
        #expect(SSHNegotiationFailure.stage(kex: nil, cipher: "aes128-ctr", mac: "hmac-sha2-256") == .keyExchangeOrHostKey)
    }

    @Test("An agreed key exchange with no cipher is the cipher stage")
    func noCipher() {
        #expect(SSHNegotiationFailure.stage(kex: "curve25519-sha256", cipher: nil, mac: nil) == .cipher)
    }

    @Test("A MAC-only server agrees key exchange and cipher, then fails the MAC")
    func noMac() {
        let stage = SSHNegotiationFailure.stage(kex: "curve25519-sha256", cipher: "aes128-ctr", mac: nil)
        #expect(stage == .mac)
    }

    @Test("Every method agreed leaves the stage undetermined")
    func everythingAgreed() {
        let stage = SSHNegotiationFailure.stage(kex: "curve25519-sha256", cipher: "aes128-ctr", mac: "hmac-sha2-256")
        #expect(stage == .undetermined)
    }

    @Test(
        "The server software is the banner's software version",
        arguments: [
            ("SSH-2.0-OpenSSH_10.3", "OpenSSH_10.3"),
            ("SSH-2.0-OpenSSH_9.9p2 Debian-1", "OpenSSH_9.9p2"),
            ("SSH-2.0-OpenSSH_9.6p1-hpn\r\n", "OpenSSH_9.6p1-hpn"),
            ("SSH-1.99-dropbear_2024.86", "dropbear_2024.86"),
        ]
    )
    func serverSoftware(banner: String, software: String) {
        #expect(SSHNegotiationFailure.serverSoftware(banner: banner) == software)
    }

    @Test("A missing or malformed banner has no server software", arguments: [nil, "", "SSH-2.0-", "SSH-2.0", "HTTP/1.1 400 Bad Request"])
    func noServerSoftware(banner: String?) {
        #expect(SSHNegotiationFailure.serverSoftware(banner: banner) == nil)
    }

    @Test("TablePro's list drops the pseudo-methods and keeps libssh2's order")
    func clientMethodsDropPseudoMethods() {
        let libssh2 = [
            "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256",
            "diffie-hellman-group14-sha256", "ext-info-c", "kex-strict-c-v00@openssh.com",
        ]

        #expect(SSHNegotiationFailure.clientMethods(libssh2) == [
            "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256",
        ])
    }

    @Test("A host key or cipher list passes through unchanged")
    func clientMethodsKeepRealMethods() {
        let hostKeys = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]

        #expect(SSHNegotiationFailure.clientMethods(hostKeys) == hostKeys)
    }

    @Test("The failure carries what the app shows")
    func carriesItsFields() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: "OpenSSH_10.3",
            supported: ["curve25519-sha256"],
            supportedHostKeys: ["ssh-ed25519"]
        )

        #expect(failure.stage == .keyExchangeOrHostKey)
        #expect(failure.serverSoftware == "OpenSSH_10.3")
        #expect(failure.supported == ["curve25519-sha256"])
        #expect(failure.supportedHostKeys == ["ssh-ed25519"])
    }

    @Test(
        "The explanation names the stage and what TablePro supports for it",
        arguments: [
            (SSHNegotiationFailure.Stage.keyExchangeOrHostKey, "no key exchange or host key method in common", "key exchange methods"),
            (.cipher, "no cipher in common", "these ciphers"),
            (.mac, "no MAC algorithm in common", "these MAC algorithms"),
        ]
    )
    func explanationNamesTheStage(stage: SSHNegotiationFailure.Stage, mismatch: String, supportedList: String) {
        let failure = SSHNegotiationFailure(
            stage: stage,
            serverSoftware: "OpenSSH_10.3",
            supported: ["first-method", "second-method"],
            supportedHostKeys: []
        )

        #expect(failure.explanation.contains(mismatch))
        #expect(failure.explanation.contains("The server runs OpenSSH_10.3."))
        #expect(failure.explanation.contains(supportedList))
        #expect(failure.explanation.contains("first-method"))
        #expect(failure.explanation.contains("second-method"))
    }

    @Test("A key exchange failure also lists the host key types")
    func explanationListsHostKeys() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: nil,
            supported: ["curve25519-sha256"],
            supportedHostKeys: ["ssh-ed25519", "rsa-sha2-512"]
        )

        #expect(failure.explanation.contains("host key types"))
        #expect(failure.explanation.contains("rsa-sha2-512"))
        #expect(!failure.explanation.contains("The server runs"))
    }

    @Test("An undetermined stage says only that the encryption could not be agreed")
    func explanationForUndeterminedStage() {
        let failure = SSHNegotiationFailure(
            stage: .undetermined,
            serverSoftware: nil,
            supported: ["ignored"],
            supportedHostKeys: []
        )

        #expect(failure.explanation == "TablePro and the SSH server could not agree on how to encrypt the connection.")
    }
}
