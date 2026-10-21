import CLibSSH2
import Foundation
import os
import TableProSSHTransport

nonisolated protocol SSHUserAuthSession {
    func methodList() -> String?
    func isAuthenticated() -> Bool
    func lastError() -> String?
    func password(_ password: String) -> Int32
    func keyboardInteractive(_ answers: KeyboardInteractiveAnswers) -> Int32
    func publicKeyFromFile(privateKeyPath: String, publicKeyPath: String?, passphrase: String?) -> Int32
    func publicKeyFromMemory(_ privateKey: String, passphrase: String?) -> Int32
}

// Answers one keyboard-interactive exchange the Mac's way: a password prompt gets the password, a code
// prompt the TOTP code, and anything else goes to the user. A code or an unknown question never gets
// the password.
nonisolated final class KeyboardInteractiveAnswers {
    typealias Ask = (KeyboardInteractiveChallenge) -> [String]?

    private let password: String?
    private let totp: (any TOTPProvider)?
    private let ask: Ask?
    private var codeAttempts = 0
    private(set) var unansweredPrompt: String?
    private(set) var declined = false
    private(set) var sentCode = false
    private(set) var askedUser = false
    private(set) var promptsSeen = 0
    private(set) var userWait: TimeInterval = 0
    // Told how long the user has taken so far, so the session's own timeout leaves that time out.
    var userWaitChanged: ((TimeInterval) -> Void)?

    init(password: String? = nil, totp: (any TOTPProvider)? = nil, ask: Ask? = nil) {
        self.password = password
        self.totp = totp
        self.ask = ask
    }

    func respond(name: String, instruction: String, prompts: [KeyboardInteractivePrompt]) -> [String] {
        promptsSeen += prompts.count
        var answers = [String?](repeating: nil, count: prompts.count)
        var pending: [Int] = []
        for (index, prompt) in prompts.enumerated() {
            switch KeyboardInteractivePromptKind(promptText: prompt.text) {
            case .password where password != nil:
                answers[index] = password
            case .totp where totp != nil:
                if let code = nextCode() {
                    answers[index] = code
                } else {
                    pending.append(index)
                }
            default:
                pending.append(index)
            }
        }

        guard !pending.isEmpty, !declined else { return answers.map { $0 ?? "" } }
        guard let ask else {
            if unansweredPrompt == nil {
                unansweredPrompt = pending
                    .map { prompts[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
            }
            return answers.map { $0 ?? "" }
        }

        let challenge = KeyboardInteractiveChallenge(name: name, instruction: instruction, prompts: pending.map { prompts[$0] })
        let asked = Date()
        let reply = ask(challenge)
        userWait += Date().timeIntervalSince(asked)
        userWaitChanged?(userWait)
        guard let replies = reply, replies.count == pending.count else {
            declined = true
            return answers.map { $0 ?? "" }
        }
        askedUser = true
        for (offset, index) in pending.enumerated() {
            answers[index] = replies[offset]
            if KeyboardInteractivePromptKind(promptText: prompts[index].text) == .totp {
                sentCode = true
            }
        }
        return answers.map { $0 ?? "" }
    }

    private func nextCode() -> String? {
        guard let totp, let code = try? totp.provideCode(attempt: codeAttempts) else { return nil }
        codeAttempts += 1
        sentCode = true
        return code
    }
}

nonisolated struct LibSSH2Authentication {
    nonisolated enum Key: Equatable, Sendable {
        case file(path: String, publicKeyPath: String?, contents: String?, publicKeyIsCertificate: Bool = false)
        case memory(String)

        static func readFile(at path: String) -> Key {
            let publicKeyPath = path + ".pub"
            let publicKey = try? String(contentsOfFile: publicKeyPath, encoding: .utf8)
            return .file(
                path: path,
                publicKeyPath: FileManager.default.fileExists(atPath: publicKeyPath) ? publicKeyPath : nil,
                contents: try? String(contentsOfFile: path, encoding: .utf8),
                publicKeyIsCertificate: publicKey.map(isCertificate) ?? false
            )
        }

        static func isCertificate(_ publicKeyLine: String) -> Bool {
            let keyType = publicKeyLine.split(whereSeparator: \.isWhitespace).first ?? ""
            return keyType.hasSuffix("-cert-v01@openssh.com")
        }

        var contents: String? {
            switch self {
            case .file(_, _, let contents, _): return contents
            case .memory(let contents): return contents
            }
        }
    }

    nonisolated private enum Offer {
        case authenticated
        case methods([String])
        case unavailable
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHAuthentication")
    private static let passwordMethod = "password"
    private static let keyboardInteractiveMethod = "keyboard-interactive"
    private static let publicKeyMethod = "publickey"
    private static let localKeyFailures: Set<Int32> = [LIBSSH2_ERROR_FILE, LIBSSH2_ERROR_KEYFILE_AUTH_FAILED]

    let session: any SSHUserAuthSession

    init(session: any SSHUserAuthSession) {
        self.session = session
    }

    init(session: OpaquePointer, username: String) {
        self.init(session: LibSSH2UserAuthSession(session: session, username: username))
    }

    func password(_ password: String, then answers: KeyboardInteractiveAnswers? = nil) throws {
        guard let offered = try methodsOnOffer() else { return }
        let answers = answers ?? KeyboardInteractiveAnswers(password: password)
        var passwordFailure: String?

        if offered.contains(Self.passwordMethod) {
            let rc = session.password(password)
            if rc == 0 { return }
            passwordFailure = failureText(of: Self.passwordMethod, rc: rc)
        }

        // A PAM server takes the password over keyboard-interactive, and a password the server took
        // as the first of two steps is followed by it.
        guard passwordFailure != nil || offered.contains(Self.keyboardInteractiveMethod) else {
            throw SSHTunnelError.authenticationFailed(Self.notOffered(
                String(localized: "The SSH server does not accept a password. It accepts %@."),
                offered: offered
            ))
        }
        try continueWithKeyboardInteractive(
            answers,
            offered: offered,
            after: passwordFailure.map { (Self.passwordMethod, $0) }
        )
    }

    func keyboardInteractive(_ answers: KeyboardInteractiveAnswers) throws {
        guard let offered = try methodsOnOffer() else { return }
        guard offered.contains(Self.keyboardInteractiveMethod) else {
            throw SSHTunnelError.authenticationFailed(Self.notOffered(
                String(localized: "The SSH server does not accept keyboard-interactive sign-in. It accepts %@."),
                offered: offered
            ))
        }
        try continueWithKeyboardInteractive(answers, offered: offered, after: nil)
    }

    func publicKey(_ key: Key, passphrase: String?, then answers: KeyboardInteractiveAnswers? = nil) throws {
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let traits = Self.traits(of: key.contents)
        if traits.isSecurityKey { throw SSHTunnelError.securityKeyUnsupported }
        if traits.isEncrypted, passphrase == nil { throw SSHTunnelError.passphraseRequired }

        guard let offered = try methodsOnOffer() else { return }
        guard offered.contains(Self.publicKeyMethod) else {
            if let answers, offered.contains(Self.keyboardInteractiveMethod) {
                try continueWithKeyboardInteractive(answers, offered: offered, after: nil)
                return
            }
            throw SSHTunnelError.authenticationFailed(Self.notOffered(
                String(localized: "The SSH server does not accept a private key. It accepts %@."),
                offered: offered
            ))
        }

        let rc: Int32
        switch key {
        case .file(let path, let publicKeyPath, _, let publicKeyIsCertificate):
            // Without the .pub, libssh2 decrypts the key before it sends anything, so a wrong
            // passphrase fails locally and -19 is only ever the server's refusal. A certificate
            // still goes: the server may trust its CA and not the bare key.
            rc = session.publicKeyFromFile(
                privateKeyPath: path,
                publicKeyPath: traits.isEncrypted && !publicKeyIsCertificate ? nil : publicKeyPath,
                passphrase: passphrase
            )
        case .memory(let contents):
            rc = session.publicKeyFromMemory(contents, passphrase: passphrase)
        }
        if rc == 0 { return }

        // These come from reading the key before anything reaches the server, so the list is
        // unchanged and reading it again would only cost a try, since OpenSSH counts a second "none".
        if Self.localKeyFailures.contains(rc) {
            if traits.isEncrypted { throw SSHTunnelError.passphraseIncorrect }
            throw SSHTunnelError.authenticationFailed(session.lastError() ?? "publickey authentication failed (error \(rc))")
        }
        let keyFailure = failureText(of: Self.publicKeyMethod, rc: rc)
        if let answers {
            try continueWithKeyboardInteractive(answers, offered: offered, after: (Self.publicKeyMethod, keyFailure))
            return
        }
        try throwNamedFailure(after: (Self.publicKeyMethod, keyFailure), offered: offered)
    }

    // The step after a refused or partly accepted first method runs at once: libssh2 drops the
    // partial-success flag, and reading the list again to find it costs a try OpenSSH counts, which
    // turned a second factor under MaxAuthTries 1 into a plain failure. The list is read again only
    // to name an error once nothing configured is left.
    private func continueWithKeyboardInteractive(
        _ answers: KeyboardInteractiveAnswers,
        offered: [String],
        after first: (method: String, failure: String)?
    ) throws {
        let rc = session.keyboardInteractive(answers)
        // A Cancel stands even when the server takes the empty answer.
        if answers.declined { throw CancellationError() }
        if rc == 0 { return }
        let detail = failureText(of: Self.keyboardInteractiveMethod, rc: rc)

        if let prompt = answers.unansweredPrompt { throw SSHTunnelError.promptUnanswerable(prompt) }
        if answers.sentCode { throw SSHTunnelError.verificationCodeRejected }
        if answers.askedUser { throw SSHTunnelError.authenticationFailed(detail) }
        guard answers.promptsSeen == 0, let first else {
            throw SSHTunnelError.authenticationFailed(first?.failure ?? detail)
        }
        try throwNamedFailure(after: first, offered: offered)
    }

    private func throwNamedFailure(after first: (method: String, failure: String), offered: [String]) throws -> Never {
        let after: [String]
        switch offer() {
        case .authenticated:
            throw SSHTunnelError.authenticationFailed(first.failure)
        case .methods(let methods):
            after = methods
        case .unavailable:
            after = []
        }
        if let remaining = SSHAuthMethods.remainingAfterPartialSuccess(of: first.method, before: offered, after: after) {
            throw SSHTunnelError.additionalFactorRequired(remaining)
        }
        throw SSHTunnelError.authenticationFailed(first.failure)
    }

    // Read right after the failing call: a later list read overwrites libssh2's last error.
    private func failureText(of method: String, rc: Int32) -> String {
        let detail = session.lastError() ?? "\(method) authentication failed (error \(rc))"
        Self.logger.debug("SSH \(method, privacy: .public) authentication failed (\(rc)): \(detail, privacy: .public)")
        return detail
    }

    // nil when the server accepted "none" and the session is already signed in.
    private func methodsOnOffer() throws -> [String]? {
        switch offer() {
        case .authenticated:
            return nil
        case .methods(let methods):
            Self.logger.debug("SSH server offers \(methods.joined(separator: ","), privacy: .public)")
            return methods
        case .unavailable:
            throw SSHTunnelError.authenticationFailed(session.lastError() ?? "No authentication methods received")
        }
    }

    private func offer() -> Offer {
        if let list = session.methodList() {
            return .methods(SSHAuthMethods.parse(list))
        }
        return session.isAuthenticated() ? .authenticated : .unavailable
    }

    private static func traits(of contents: String?) -> (isEncrypted: Bool, isSecurityKey: Bool) {
        guard let contents else { return (false, false) }
        if let traits = SSHPrivateKeyTraits(openSSH: contents) {
            return (traits.isEncrypted, traits.isSecurityKey)
        }
        return (PEMDocument.inspect(contents).usesPassphrase, false)
    }

    private static func notOffered(_ format: String, offered: [String]) -> String {
        guard !offered.isEmpty else {
            return String(localized: "The SSH server offers no sign-in method.")
        }
        return String(format: format, offered.formatted(.list(type: .or)))
    }
}

nonisolated struct LibSSH2UserAuthSession: SSHUserAuthSession {
    let session: OpaquePointer
    let username: String

    func methodList() -> String? {
        guard let list = libssh2_userauth_list(session, username, UInt32(username.utf8.count)) else { return nil }
        return String(cString: list)
    }

    func isAuthenticated() -> Bool {
        libssh2_userauth_authenticated(session) != 0
    }

    func lastError() -> String? {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        guard let message, length > 0 else { return nil }
        return String(cString: message)
    }

    func password(_ password: String) -> Int32 {
        libssh2_userauth_password_ex(
            session,
            username,
            UInt32(username.utf8.count),
            password,
            UInt32(password.utf8.count),
            nil
        )
    }

    func keyboardInteractive(_ answers: KeyboardInteractiveAnswers) -> Int32 {
        let abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?> = libssh2_session_abstract(session)
        let previous = abstract.pointee
        abstract.pointee = Unmanaged.passUnretained(answers).toOpaque()
        // libssh2 times the whole call from its start, the callback included, so a user typing a code
        // would otherwise run out the network timeout.
        let session = self.session
        let timeout = libssh2_session_get_timeout(session)
        if timeout > 0 {
            answers.userWaitChanged = { waited in
                libssh2_session_set_timeout(session, timeout + Int(waited * 1_000))
            }
        }
        defer {
            abstract.pointee = previous
            answers.userWaitChanged = nil
            libssh2_session_set_timeout(session, timeout)
        }

        return withExtendedLifetime(answers) {
            libssh2_userauth_keyboard_interactive_ex(session, username, UInt32(username.utf8.count)) {
                name, nameLength, instruction, instructionLength, count, prompts, responses, slot in
                guard count > 0, let prompts, let responses, let context = slot?.pointee else { return }
                let answers = Unmanaged<KeyboardInteractiveAnswers>.fromOpaque(context).takeUnretainedValue()
                let asked = (0 ..< Int(count)).map { index in
                    KeyboardInteractivePrompt(
                        text: LibSSH2UserAuthSession.text(of: prompts[index]),
                        echo: prompts[index].echo != 0
                    )
                }
                let replies = answers.respond(
                    name: LibSSH2UserAuthSession.text(name, length: nameLength),
                    instruction: LibSSH2UserAuthSession.text(instruction, length: instructionLength),
                    prompts: asked
                )
                for index in 0 ..< Int(count) {
                    // libssh2 frees each response, so it has to come from the C heap.
                    let response = strdup(index < replies.count ? replies[index] : "")
                    responses[index].text = response
                    responses[index].length = response.map { UInt32(strlen($0)) } ?? 0
                }
            }
        }
    }

    func publicKeyFromFile(privateKeyPath: String, publicKeyPath: String?, passphrase: String?) -> Int32 {
        libssh2_userauth_publickey_fromfile_ex(
            session,
            username,
            UInt32(username.utf8.count),
            publicKeyPath,
            privateKeyPath,
            passphrase
        )
    }

    func publicKeyFromMemory(_ privateKey: String, passphrase: String?) -> Int32 {
        privateKey.withCString { keyPointer in
            libssh2_userauth_publickey_frommemory(
                session,
                username,
                username.utf8.count,
                nil, 0,
                keyPointer, privateKey.utf8.count,
                passphrase
            )
        }
    }

    private static func text(of prompt: LIBSSH2_USERAUTH_KBDINT_PROMPT) -> String {
        guard let text = prompt.text, prompt.length > 0 else { return "" }
        return String(bytes: UnsafeBufferPointer(start: text, count: prompt.length), encoding: .utf8) ?? ""
    }

    private static func text(_ pointer: UnsafePointer<CChar>?, length: Int32) -> String {
        guard let pointer, length > 0 else { return "" }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: Int(length)) {
            String(bytes: UnsafeBufferPointer(start: $0, count: Int(length)), encoding: .utf8) ?? ""
        }
    }
}
