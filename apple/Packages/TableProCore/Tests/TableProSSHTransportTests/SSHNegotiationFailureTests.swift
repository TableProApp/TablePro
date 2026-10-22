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
            ("SSH-2.0-OpenSSH_7.4\u{1B}[31m", "OpenSSH_7.4"),
            ("SSH-2.0-OpenSSH_7.4\u{202E}lmth.exe", "OpenSSH_7.4"),
        ]
    )
    func serverSoftware(banner: String, software: String) {
        #expect(SSHNegotiationFailure.serverSoftware(banner: banner) == software)
    }

    @Test(
        "A missing or malformed banner has no server software",
        arguments: [nil, "", "SSH-2.0-", "SSH-2.0", "HTTP/1.1 400 Bad Request", "SSH-2.0-\u{202E}OpenSSH"]
    )
    func noServerSoftware(banner: String?) {
        #expect(SSHNegotiationFailure.serverSoftware(banner: banner) == nil)
    }

    @Test("TablePro's list drops the pseudo-methods and keeps libssh2's order")
    func clientMethodsDropPseudoMethods() {
        let libssh2 = [
            "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256",
            "diffie-hellman-group14-sha256", "ext-info-c", "kex-strict-c-v00@openssh.com",
        ]

        #expect(SSHNegotiationFailure.withoutPseudoMethods(libssh2) == [
            "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256",
        ])
    }

    @Test("A host key or cipher list passes through unchanged")
    func clientMethodsKeepRealMethods() {
        let hostKeys = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]

        #expect(SSHNegotiationFailure.withoutPseudoMethods(hostKeys) == hostKeys)
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

    @Test("A server whose key exchange methods are all ones TablePro dropped is told so, without its pseudo-methods")
    func retiredKeyExchange() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: "OpenSSH_7.4",
            supported: ["curve25519-sha256"],
            supportedHostKeys: ["ssh-ed25519"],
            proposal: Self.proposal(
                kex: ["diffie-hellman-group14-sha1", "ext-info-s", "kex-strict-s-v00@openssh.com"],
                hostKeys: ["ssh-ed25519"]
            )
        )

        #expect(failure.offered == ["diffie-hellman-group14-sha1"])
        #expect(failure.explanation.contains(
            "The server runs OpenSSH_7.4. The server offers only key exchange methods TablePro no longer supports: diffie-hellman-group14-sha1. TablePro supports"
        ))
        #expect(!failure.explanation.contains("host key types TablePro no longer supports"))
    }

    @Test("A server with only an ssh-rsa host key names the host key, not the key exchange")
    func retiredHostKey() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: nil,
            supported: ["curve25519-sha256"],
            supportedHostKeys: ["ssh-ed25519", "rsa-sha2-256"],
            proposal: Self.proposal(kex: ["curve25519-sha256"], hostKeys: ["ssh-rsa"])
        )

        #expect(failure.offeredHostKeys == ["ssh-rsa"])
        #expect(failure.explanation.contains("The server offers only host key types TablePro no longer supports: ssh-rsa."))
        #expect(!failure.explanation.contains("key exchange methods TablePro no longer supports"))
    }

    @Test(
        "A cipher or MAC stage names the server's offer when every method in it is one TablePro dropped",
        arguments: [
            (SSHNegotiationFailure.Stage.cipher, ["3des-cbc", "blowfish-cbc"], "The server offers only ciphers TablePro no longer supports: "),
            (.mac, ["hmac-sha1", "hmac-md5"], "The server offers only MAC algorithms TablePro no longer supports: "),
        ]
    )
    func retiredCipherOrMac(stage: SSHNegotiationFailure.Stage, offered: [String], sentence: String) {
        let failure = SSHNegotiationFailure(
            stage: stage,
            serverSoftware: nil,
            supported: ["aes128-ctr", "hmac-sha2-256"],
            supportedHostKeys: [],
            proposal: Self.proposal(ciphers: offered, macs: offered)
        )

        #expect(failure.offered == offered)
        #expect(failure.explanation.contains(sentence + offered.formatted(.list(type: .and)) + "."))
    }

    @Test("A name the server repeats is named once")
    func repeatedOfferIsNamedOnce() {
        let failure = SSHNegotiationFailure(
            stage: .keyExchangeOrHostKey,
            serverSoftware: nil,
            supported: ["curve25519-sha256"],
            supportedHostKeys: ["ssh-ed25519"],
            proposal: Self.proposal(kex: ["curve25519-sha256"], hostKeys: Array(repeating: "ssh-rsa", count: 5_000))
        )

        #expect(failure.offeredHostKeys == ["ssh-rsa"])
        #expect(failure.explanation.contains("The server offers only host key types TablePro no longer supports: ssh-rsa. "))
    }

    @Test("An offer that holds a method TablePro never had is not called dropped")
    func mixedOfferIsNotRetired() {
        let failure = SSHNegotiationFailure(
            stage: .mac,
            serverSoftware: nil,
            supported: ["hmac-sha2-256"],
            supportedHostKeys: [],
            proposal: Self.proposal(macs: ["hmac-sha1", "umac-128-etm@openssh.com"])
        )

        #expect(failure.offered == ["hmac-sha1", "umac-128-etm@openssh.com"])
        #expect(!failure.explanation.contains("no longer supports"))
    }

    @Test("The offer named is the direction that has nothing in common with TablePro")
    func offerIsTheFailingDirection() {
        let failure = SSHNegotiationFailure(
            stage: .cipher,
            serverSoftware: nil,
            supported: ["aes128-ctr"],
            supportedHostKeys: [],
            proposal: Self.proposal(ciphers: ["aes128-ctr"], ciphersServerToClient: ["3des-cbc"])
        )

        #expect(failure.offered == ["3des-cbc"])
    }

    @Test("Without the server's KEXINIT nothing is named as offered")
    func noProposal() {
        let failure = SSHNegotiationFailure(stage: .mac, serverSoftware: nil, supported: ["hmac-sha2-256"], supportedHostKeys: [])

        #expect(failure.offered.isEmpty)
        #expect(!failure.explanation.contains("The server offers"))
    }

    @Test("A key with no signature algorithm in common says how TablePro signs RSA keys")
    func keySignature() {
        let failure = SSHNegotiationFailure.keySignature(serverBanner: "SSH-2.0-OpenSSH_7.4\r\n")

        #expect(failure.stage == .keySignature)
        #expect(failure.explanation == "TablePro and the SSH server have no signature algorithm in common for this key. "
            + "The server runs OpenSSH_7.4. "
            + "TablePro signs RSA keys with rsa-sha2-256 or rsa-sha2-512, not with ssh-rsa, which uses SHA-1.")
    }

    private static func proposal(
        kex: [String] = ["curve25519-sha256"],
        hostKeys: [String] = ["ssh-ed25519"],
        ciphers: [String] = ["aes128-ctr"],
        ciphersServerToClient: [String]? = nil,
        macs: [String] = ["hmac-sha2-256"]
    ) -> SSHServerProposal {
        SSHServerProposal(
            keyExchange: kex,
            hostKeys: hostKeys,
            ciphersClientToServer: ciphers,
            ciphersServerToClient: ciphersServerToClient ?? ciphers,
            macsClientToServer: macs,
            macsServerToClient: macs
        )
    }
}
