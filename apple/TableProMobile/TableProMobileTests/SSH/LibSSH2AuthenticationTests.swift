import Foundation
import TableProSSHTransport
import Testing

@testable import TableProMobile

struct LibSSH2AuthenticationTests {
    // libssh2's return codes, named here because the test target does not import CLibSSH2.
    static let rcFile: Int32 = -16
    static let rcAuthenticationFailed: Int32 = -18
    static let rcPublicKeyUnverified: Int32 = -19
    static let rcKeyFileAuthFailed: Int32 = -48

    static let serverText = "Username/PublicKey combination invalid"
    static let securityKey = openSSHKey(type: "sk-ssh-ed25519@openssh.com", encrypted: false)
    static let encryptedPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,00000000000000000000000000000000

        AAAA
        -----END RSA PRIVATE KEY-----
        """

    static let securityKeys: [LibSSH2Authentication.Key] = [
        .memory(securityKey),
        .file(path: "/keys/id_ed25519_sk", publicKeyPath: "/keys/id_ed25519_sk.pub", contents: securityKey),
    ]

    static let encryptedKeys = [openSSHKey(encrypted: true), encryptedPEM]

    static let keyFailures: [KeyFailureRow] = [
        KeyFailureRow(encrypted: true, rc: rcFile, expected: .passphraseIncorrect),
        KeyFailureRow(encrypted: true, rc: rcKeyFileAuthFailed, expected: .passphraseIncorrect),
        KeyFailureRow(encrypted: true, rc: rcPublicKeyUnverified, expected: .authenticationFailed(serverText)),
        KeyFailureRow(encrypted: true, rc: rcAuthenticationFailed, expected: .authenticationFailed(serverText)),
        KeyFailureRow(encrypted: false, rc: rcFile, expected: .authenticationFailed(serverText)),
        KeyFailureRow(encrypted: false, rc: rcPublicKeyUnverified, expected: .authenticationFailed(serverText)),
    ]

    static let localKeyFailures: [KeyFailureRow] = [
        KeyFailureRow(encrypted: true, rc: rcFile, expected: .passphraseIncorrect),
        KeyFailureRow(encrypted: true, rc: rcKeyFileAuthFailed, expected: .passphraseIncorrect),
        KeyFailureRow(encrypted: false, rc: rcFile, expected: .authenticationFailed(serverText)),
    ]

    @Test("A NULL method list on a signed-in session is success", arguments: [true, false])
    func nullListWhileSignedIn(withKey: Bool) throws {
        let session = ScriptedAuthSession(lists: [nil], authenticated: true)
        let authentication = LibSSH2Authentication(session: session)

        if withKey {
            try authentication.publicKey(.memory(Self.openSSHKey(encrypted: false)), passphrase: nil)
        } else {
            try authentication.password("secret")
        }

        #expect(session.calls == [.methodList, .isAuthenticated])
    }

    @Test("A NULL method list on a session that is not signed in fails with libssh2's text")
    func nullListWithoutSignIn() {
        let session = ScriptedAuthSession(lists: [nil], listError: "Failed getting response")

        #expect(throws: SSHTunnelError.authenticationFailed("Failed getting response")) {
            try LibSSH2Authentication(session: session).password("secret")
        }
    }

    @Test("A password the server accepts signs in")
    func passwordAccepted() throws {
        let session = ScriptedAuthSession(lists: ["publickey,password"])

        try LibSSH2Authentication(session: session).password("secret")

        #expect(session.calls == [.methodList, .password])
    }

    @Test("The password's failure text is read before anything else is sent")
    func lastErrorBeforeTheListAgain() {
        let session = ScriptedAuthSession(
            lists: ["password", nil],
            listError: "Failed getting response",
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )

        #expect(throws: SSHTunnelError.authenticationFailed("Authentication failed (username/password)")) {
            try LibSSH2Authentication(session: session).password("secret")
        }
        #expect(session.calls.prefix(3) == [.methodList, .password, .lastError])
    }

    @Test("A password accepted as the first of two steps goes on to keyboard-interactive without reading the list again")
    func passwordPartialSuccessContinues() throws {
        let session = ScriptedAuthSession(
            lists: ["password", "keyboard-interactive"],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            prompts: ["Verification code: "]
        )
        let answers = KeyboardInteractiveAnswers(password: "secret", totp: FixedCode("123456"))

        try LibSSH2Authentication(session: session).password("secret", then: answers)

        #expect(session.calls == [.methodList, .password, .lastError, .keyboardInteractive])
        #expect(session.sentAnswers == ["123456"])
    }

    @Test("A first step the server took, followed by one TablePro has nothing for, names that step")
    func passwordPartialSuccessNamesWhatIsLeft() {
        let session = ScriptedAuthSession(
            lists: ["password", "publickey"],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )

        #expect(throws: SSHTunnelError.additionalFactorRequired(["publickey"])) {
            try LibSSH2Authentication(session: session).password("secret")
        }
    }

    @Test("A code the server refuses is named as the code")
    func refusedCodeIsNamed() {
        let session = ScriptedAuthSession(
            lists: ["password", "keyboard-interactive"],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            prompts: ["Verification code: "],
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )

        #expect(throws: SSHTunnelError.verificationCodeRejected) {
            try LibSSH2Authentication(session: session).password(
                "secret",
                then: KeyboardInteractiveAnswers(password: "secret", totp: FixedCode("000000"))
            )
        }
        #expect(!session.calls.dropFirst().contains(.methodList))
    }

    @Test("A question nothing stored answers goes to the user, once per exchange")
    func unknownPromptIsAsked() throws {
        let session = ScriptedAuthSession(lists: ["keyboard-interactive"], prompts: ["Verification code: ", "Enter PIN: "])
        var asked: [KeyboardInteractiveChallenge] = []
        let answers = KeyboardInteractiveAnswers(password: "secret") { challenge in
            asked.append(challenge)
            return ["424242", "1234"]
        }

        try LibSSH2Authentication(session: session).keyboardInteractive(answers)

        #expect(asked.count == 1)
        #expect(asked.first?.prompts.map(\.text) == ["Verification code: ", "Enter PIN: "])
        #expect(session.sentAnswers == ["424242", "1234"])
    }

    @Test("A question the user declines ends sign-in as a cancellation")
    func declinedPromptCancels() {
        let session = ScriptedAuthSession(
            lists: ["keyboard-interactive"],
            prompts: ["Verification code: "],
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )
        let answers = KeyboardInteractiveAnswers(password: "secret") { _ in nil }

        #expect(throws: CancellationError.self) {
            try LibSSH2Authentication(session: session).keyboardInteractive(answers)
        }
        #expect(session.sentAnswers == [""])
    }

    @Test("Cancel stands even when the server takes the empty answer")
    func declinedPromptCancelsEvenWhenAccepted() {
        let session = ScriptedAuthSession(lists: ["keyboard-interactive"], prompts: ["Verification code: "])
        let answers = KeyboardInteractiveAnswers(password: "secret") { _ in nil }

        #expect(throws: CancellationError.self) {
            try LibSSH2Authentication(session: session).keyboardInteractive(answers)
        }
    }

    @Test("A code the user typed and the server refused is named as the code, not the password")
    func refusedTypedCodeIsNamed() {
        let session = ScriptedAuthSession(
            lists: ["password", "keyboard-interactive"],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            prompts: ["Verification code: "],
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )
        let answers = KeyboardInteractiveAnswers(password: "secret") { _ in ["000000"] }

        #expect(throws: SSHTunnelError.verificationCodeRejected) {
            try LibSSH2Authentication(session: session).password("secret", then: answers)
        }
    }

    @Test("Another answer the user typed and the server refused keeps the server's words")
    func refusedTypedAnswerKeepsServerText() {
        let session = ScriptedAuthSession(
            lists: ["password", "keyboard-interactive"],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            prompts: ["Enter PIN: "],
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )
        let answers = KeyboardInteractiveAnswers(password: "secret") { _ in ["1234"] }

        #expect(throws: SSHTunnelError.authenticationFailed("Authentication failed (keyboard-interactive)")) {
            try LibSSH2Authentication(session: session).password("secret", then: answers)
        }
    }

    @Test("A key the server took as the first of two steps goes on to keyboard-interactive")
    func keyPartialSuccessContinues() throws {
        let session = ScriptedAuthSession(
            lists: ["publickey", "keyboard-interactive"],
            prompts: ["Verification code: "],
            key: .failing(Self.rcPublicKeyUnverified, Self.serverText)
        )

        try LibSSH2Authentication(session: session).publicKey(
            .memory(Self.openSSHKey(encrypted: false)),
            passphrase: nil,
            then: KeyboardInteractiveAnswers(totp: FixedCode("654321"))
        )

        #expect(session.calls == [.methodList, .keyMemory, .lastError, .keyboardInteractive])
        #expect(session.sentAnswers == ["654321"])
    }

    @Test("A server that takes no key but keyboard-interactive is asked that way, as on the Mac")
    func keyNotOfferedFallsToKeyboardInteractive() throws {
        let session = ScriptedAuthSession(lists: ["password,keyboard-interactive"], prompts: ["Password: "])

        try LibSSH2Authentication(session: session).publicKey(
            .memory(Self.openSSHKey(encrypted: false)),
            passphrase: nil,
            then: KeyboardInteractiveAnswers { _ in ["typed"] }
        )

        #expect(session.calls == [.methodList, .keyboardInteractive])
        #expect(session.sentAnswers == ["typed"])
    }

    @Test("Keyboard Interactive on a server without it names what the server takes")
    func keyboardInteractiveNotOffered() {
        let session = ScriptedAuthSession(lists: ["publickey"])

        let error = #expect(throws: SSHTunnelError.self) {
            try LibSSH2Authentication(session: session).keyboardInteractive(KeyboardInteractiveAnswers())
        }

        guard case .authenticationFailed(let message)? = error else {
            Issue.record("expected authenticationFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("publickey"))
        #expect(session.calls == [.methodList])
    }

    @Test("A refused password is tried again over keyboard-interactive")
    func passwordRetriedOverKeyboardInteractive() throws {
        let methods = "publickey,password,keyboard-interactive"
        let session = ScriptedAuthSession(
            lists: [methods, methods],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            prompts: ["Password: "]
        )

        try LibSSH2Authentication(session: session).password("secret")

        #expect(session.sentAnswers == ["secret"])
    }

    @Test("A server without the password method gets the password over keyboard-interactive")
    func passwordOverKeyboardInteractiveOnly() throws {
        let session = ScriptedAuthSession(lists: ["publickey,keyboard-interactive"], prompts: ["Password: "])

        try LibSSH2Authentication(session: session).password("secret")

        #expect(session.calls == [.methodList, .keyboardInteractive])
        #expect(session.sentAnswers == ["secret"])
    }

    @Test("A code prompt never gets the password and is named")
    func codePromptIsUnanswerable() {
        let session = ScriptedAuthSession(
            lists: ["keyboard-interactive", "keyboard-interactive"],
            prompts: ["Verification code: "],
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )

        #expect(throws: SSHTunnelError.promptUnanswerable("Verification code:")) {
            try LibSSH2Authentication(session: session).password("secret")
        }
        #expect(session.sentAnswers == [""])
    }

    @Test("A refused password keeps its own text when keyboard-interactive asks nothing")
    func passwordTextOutlivesAnEmptyKeyboardInteractive() {
        let methods = "password,keyboard-interactive"
        let session = ScriptedAuthSession(
            lists: [methods, methods, methods],
            password: .failing(Self.rcAuthenticationFailed, "Authentication failed (username/password)"),
            keyboardInteractive: .failing(Self.rcAuthenticationFailed, "Authentication failed (keyboard-interactive)")
        )

        #expect(throws: SSHTunnelError.authenticationFailed("Authentication failed (username/password)")) {
            try LibSSH2Authentication(session: session).password("secret")
        }
    }

    @Test("A server that takes neither a password nor keyboard-interactive names what it takes")
    func passwordNotOffered() {
        let session = ScriptedAuthSession(lists: ["publickey"])

        let error = #expect(throws: SSHTunnelError.self) {
            try LibSSH2Authentication(session: session).password("secret")
        }

        guard case .authenticationFailed(let message)? = error else {
            Issue.record("expected authenticationFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("publickey"))
        #expect(session.calls == [.methodList])
    }

    @Test("A password prompt gets the password", arguments: ["Password: ", "Password for deploy@db.internal: "])
    func passwordPromptGetsThePassword(prompt: String) {
        let answers = KeyboardInteractiveAnswers(password: "secret")

        #expect(answers.respond(name: "", instruction: "", prompts: [Self.prompt(prompt)]) == ["secret"])
        #expect(answers.unansweredPrompt == nil)
    }

    @Test("With nobody to ask, a code or unknown prompt gets an empty answer and is named", arguments: ["Verification code: ", "One-time password: ", "Enter PIN: "])
    func otherPromptsGetNothing(prompt: String) {
        let answers = KeyboardInteractiveAnswers(password: "secret")

        #expect(answers.respond(name: "", instruction: "", prompts: [Self.prompt(prompt)]) == [""])
        #expect(answers.unansweredPrompt == prompt.trimmingCharacters(in: .whitespaces))
    }

    @Test("A code prompt gets the generated code and never the password")
    func codePromptGetsTheCode() {
        let answers = KeyboardInteractiveAnswers(password: "secret", totp: FixedCode("123456"))

        let replies = answers.respond(
            name: "",
            instruction: "",
            prompts: [Self.prompt("Password: "), Self.prompt("Verification code: ")]
        )

        #expect(replies == ["secret", "123456"])
        #expect(answers.sentCode)
    }

    @Test("The user is asked only the prompts nothing stored answers, with the server's words")
    func onlyOpenPromptsAreAsked() {
        var asked: KeyboardInteractiveChallenge?
        let answers = KeyboardInteractiveAnswers(password: "secret") { challenge in
            asked = challenge
            return ["777"]
        }

        let replies = answers.respond(
            name: "Duo",
            instruction: "Approve the push or type a passcode.",
            prompts: [Self.prompt("Password: "), Self.prompt("Passcode or option (1-3): ", echo: true)]
        )

        #expect(replies == ["secret", "777"])
        #expect(asked == KeyboardInteractiveChallenge(
            name: "Duo",
            instruction: "Approve the push or type a passcode.",
            prompts: [Self.prompt("Passcode or option (1-3): ", echo: true)]
        ))
    }

    @Test("The time the user takes is reported, so the session's timeout can leave it out")
    func userWaitIsReported() {
        var reported: [TimeInterval] = []
        let answers = KeyboardInteractiveAnswers { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return ["424242"]
        }
        answers.userWaitChanged = { reported.append($0) }

        _ = answers.respond(name: "", instruction: "", prompts: [Self.prompt("Verification code: ")])
        _ = answers.respond(name: "", instruction: "", prompts: [Self.prompt("Verification code: ")])

        #expect(reported.count == 2)
        #expect((reported.first ?? 0) >= 0.05)
        #expect((reported.last ?? 0) >= 0.1)
    }

    private static func prompt(_ text: String, echo: Bool = false) -> KeyboardInteractivePrompt {
        KeyboardInteractivePrompt(text: text, echo: echo)
    }

    @Test("A security key is named before anything reaches the server", arguments: LibSSH2AuthenticationTests.securityKeys)
    func securityKeyIsNamed(key: LibSSH2Authentication.Key) {
        let session = ScriptedAuthSession(lists: ["publickey"])

        #expect(throws: SSHTunnelError.securityKeyUnsupported) {
            try LibSSH2Authentication(session: session).publicKey(key, passphrase: "hunter2")
        }
        #expect(session.calls.isEmpty)
    }

    @Test("An encrypted key with no passphrase is named before anything reaches the server", arguments: LibSSH2AuthenticationTests.encryptedKeys)
    func encryptedKeyNeedsAPassphrase(text: String) {
        let session = ScriptedAuthSession(lists: ["publickey"])

        #expect(throws: SSHTunnelError.passphraseRequired) {
            try LibSSH2Authentication(session: session).publicKey(.memory(text), passphrase: "")
        }
        #expect(session.calls.isEmpty)
    }

    @Test("A key failure is named by the key and libssh2's return code", arguments: LibSSH2AuthenticationTests.keyFailures)
    func keyFailure(row: KeyFailureRow) {
        let session = ScriptedAuthSession(lists: ["publickey", "publickey"], key: .failing(row.rc, Self.serverText))

        #expect(throws: row.expected) {
            try LibSSH2Authentication(session: session).publicKey(
                .memory(Self.openSSHKey(encrypted: row.encrypted)),
                passphrase: "hunter2"
            )
        }
    }

    @Test("An encrypted key accepted as the first of two steps names the next step, not the passphrase")
    func keyPartialSuccessComesFirst() {
        let session = ScriptedAuthSession(
            lists: ["publickey", "keyboard-interactive"],
            key: .failing(Self.rcPublicKeyUnverified, Self.serverText)
        )

        #expect(throws: SSHTunnelError.additionalFactorRequired(["keyboard-interactive"])) {
            try LibSSH2Authentication(session: session).publicKey(
                .memory(Self.openSSHKey(encrypted: true)),
                passphrase: "hunter2"
            )
        }
        #expect(session.calls == [.methodList, .keyMemory, .lastError, .methodList])
    }

    @Test("A key that fails to read never asks the server for its methods again", arguments: LibSSH2AuthenticationTests.localKeyFailures)
    func localKeyFailureSkipsTheList(row: KeyFailureRow) {
        let session = ScriptedAuthSession(lists: ["publickey", "keyboard-interactive"], key: .failing(row.rc, Self.serverText))

        #expect(throws: row.expected) {
            try LibSSH2Authentication(session: session).publicKey(
                .memory(Self.openSSHKey(encrypted: row.encrypted)),
                passphrase: "hunter2"
            )
        }
        #expect(!session.calls.dropFirst().contains(.methodList))
    }

    @Test("An encrypted key file goes without its .pub and a plain one keeps it", arguments: [true, false])
    func encryptedKeyFileDropsThePublicKey(encrypted: Bool) throws {
        let session = ScriptedAuthSession(lists: ["publickey"])
        let key = LibSSH2Authentication.Key.file(
            path: "/keys/id_ed25519",
            publicKeyPath: "/keys/id_ed25519.pub",
            contents: Self.openSSHKey(encrypted: encrypted)
        )

        try LibSSH2Authentication(session: session).publicKey(key, passphrase: "hunter2")

        #expect(session.calls.last == .keyFile(publicKeyPath: encrypted ? nil : "/keys/id_ed25519.pub"))
    }

    @Test("An encrypted key file keeps a .pub that holds its certificate")
    func encryptedKeyFileKeepsItsCertificate() throws {
        let session = ScriptedAuthSession(lists: ["publickey"])
        let key = LibSSH2Authentication.Key.file(
            path: "/keys/id_ed25519",
            publicKeyPath: "/keys/id_ed25519.pub",
            contents: Self.openSSHKey(encrypted: true),
            publicKeyIsCertificate: true
        )

        try LibSSH2Authentication(session: session).publicKey(key, passphrase: "hunter2")

        #expect(session.calls.last == .keyFile(publicKeyPath: "/keys/id_ed25519.pub"))
    }

    @Test("A key file reads whether its .pub holds a certificate", arguments: [
        ("ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQ= user\n", true),
        ("rsa-sha2-512-cert-v01@openssh.com AAAA", true),
        ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user\n", false),
    ])
    func keyFileReadsItsCertificate(publicKeyLine: String, isCertificate: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("id_ed25519").path
        try Self.openSSHKey(encrypted: true).write(toFile: path, atomically: true, encoding: .utf8)
        try publicKeyLine.write(toFile: path + ".pub", atomically: true, encoding: .utf8)

        let key = LibSSH2Authentication.Key.readFile(at: path)

        #expect(key == .file(
            path: path,
            publicKeyPath: path + ".pub",
            contents: Self.openSSHKey(encrypted: true),
            publicKeyIsCertificate: isCertificate
        ))
    }

    @Test("A server that takes no key names what it takes")
    func keyNotOffered() {
        let session = ScriptedAuthSession(lists: ["password,keyboard-interactive"])

        let error = #expect(throws: SSHTunnelError.self) {
            try LibSSH2Authentication(session: session).publicKey(.memory(Self.openSSHKey(encrypted: false)), passphrase: nil)
        }

        guard case .authenticationFailed(let message)? = error else {
            Issue.record("expected authenticationFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("keyboard-interactive"))
        #expect(session.calls == [.methodList])
    }

    // An openssh-key-v1 header: cipher, KDF name, KDF options, key count, then the public key blob.
    static func openSSHKey(type: String = "ssh-ed25519", encrypted: Bool) -> String {
        let publicKey = Data([field(Data(type.utf8)), field(Data(repeating: 7, count: 32))].joined())
        let body = Data([
            Data("openssh-key-v1\0".utf8),
            field(Data((encrypted ? "aes256-ctr" : "none").utf8)),
            field(Data((encrypted ? "bcrypt" : "none").utf8)),
            field(Data()),
            uint32(1),
            field(publicKey),
            field(Data(repeating: 0, count: 64)),
        ].joined())
        return """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(body.base64EncodedString(options: .lineLength64Characters))
            -----END OPENSSH PRIVATE KEY-----
            """
    }

    private static func field(_ bytes: Data) -> Data {
        uint32(UInt32(bytes.count)) + bytes
    }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

nonisolated struct KeyFailureRow: Sendable, CustomTestStringConvertible {
    let encrypted: Bool
    let rc: Int32
    let expected: SSHTunnelError

    var testDescription: String {
        "\(encrypted ? "encrypted" : "plain") key, rc \(rc)"
    }
}

// Stands in for a libssh2 session. libssh2 keeps one last error per session, and a failed
// list read overwrites it, so this one does too.
nonisolated final class ScriptedAuthSession: SSHUserAuthSession {
    nonisolated struct Reply: Sendable {
        static let accepted = Reply(rc: 0, error: nil)

        let rc: Int32
        let error: String?

        static func failing(_ rc: Int32, _ error: String) -> Reply {
            Reply(rc: rc, error: error)
        }
    }

    nonisolated enum Call: Equatable {
        case methodList
        case isAuthenticated
        case lastError
        case password
        case keyboardInteractive
        case keyFile(publicKeyPath: String?)
        case keyMemory
    }

    private var lists: [String?]
    private let authenticated: Bool
    private let listError: String?
    private let passwordReply: Reply
    private let prompts: [String]
    private let keyboardInteractiveReply: Reply
    private let keyReply: Reply
    private var currentError: String?

    private(set) var calls: [Call] = []
    private(set) var sentAnswers: [String] = []

    init(
        lists: [String?],
        authenticated: Bool = false,
        listError: String? = nil,
        password: Reply = .accepted,
        prompts: [String] = [],
        keyboardInteractive: Reply = .accepted,
        key: Reply = .accepted
    ) {
        self.lists = lists
        self.authenticated = authenticated
        self.listError = listError
        self.passwordReply = password
        self.prompts = prompts
        self.keyboardInteractiveReply = keyboardInteractive
        self.keyReply = key
    }

    func methodList() -> String? {
        calls.append(.methodList)
        let list = lists.isEmpty ? nil : lists.removeFirst()
        if list == nil, let listError {
            currentError = listError
        }
        return list
    }

    func isAuthenticated() -> Bool {
        calls.append(.isAuthenticated)
        return authenticated
    }

    func lastError() -> String? {
        calls.append(.lastError)
        return currentError
    }

    func password(_ password: String) -> Int32 {
        calls.append(.password)
        return reply(passwordReply)
    }

    func keyboardInteractive(_ answers: KeyboardInteractiveAnswers) -> Int32 {
        calls.append(.keyboardInteractive)
        if !prompts.isEmpty {
            sentAnswers += answers.respond(
                name: "",
                instruction: "",
                prompts: prompts.map { KeyboardInteractivePrompt(text: $0, echo: false) }
            )
        }
        return reply(keyboardInteractiveReply)
    }

    func publicKeyFromFile(privateKeyPath: String, publicKeyPath: String?, passphrase: String?) -> Int32 {
        calls.append(.keyFile(publicKeyPath: publicKeyPath))
        return reply(keyReply)
    }

    func publicKeyFromMemory(_ privateKey: String, passphrase: String?) -> Int32 {
        calls.append(.keyMemory)
        return reply(keyReply)
    }

    private func reply(_ reply: Reply) -> Int32 {
        if reply.rc != 0 {
            currentError = reply.error
        }
        return reply.rc
    }
}

nonisolated struct FixedCode: TOTPProvider {
    let code: String

    init(_ code: String) {
        self.code = code
    }

    func provideCode(attempt: Int) throws -> String {
        code
    }
}
