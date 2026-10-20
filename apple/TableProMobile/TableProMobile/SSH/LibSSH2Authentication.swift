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

nonisolated final class KeyboardInteractiveAnswers {
    private let password: String
    private(set) var unansweredPrompt: String?

    init(password: String) {
        self.password = password
    }

    // A code or an unknown question gets an empty answer, never the password.
    func answer(_ prompt: String) -> String {
        if KeyboardInteractivePromptKind(promptText: prompt) == .password {
            return password
        }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if unansweredPrompt == nil, !question.isEmpty {
            unansweredPrompt = question
        }
        return ""
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

    nonisolated private struct Failure {
        let detail: String
        let methodsAfter: [String]
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

    func password(_ password: String) throws {
        guard let offered = try methodsOnOffer() else { return }
        var available = offered
        var passwordFailure: String?

        if offered.contains(Self.passwordMethod) {
            let rc = session.password(password)
            if rc == 0 { return }
            guard let failure = try readFailure(of: Self.passwordMethod, rc: rc, offered: offered) else { return }
            passwordFailure = failure.detail
            available = failure.methodsAfter
        }

        // A PAM server can take the password over keyboard-interactive instead.
        guard available.contains(Self.keyboardInteractiveMethod) else {
            throw SSHTunnelError.authenticationFailed(passwordFailure ?? Self.notOffered(
                String(localized: "The SSH server does not accept a password. It accepts %@."),
                offered: offered
            ))
        }

        let answers = KeyboardInteractiveAnswers(password: password)
        let rc = session.keyboardInteractive(answers)
        if rc == 0 { return }
        guard let failure = try readFailure(of: Self.keyboardInteractiveMethod, rc: rc, offered: available) else { return }
        if let prompt = answers.unansweredPrompt {
            throw SSHTunnelError.promptUnanswerable(prompt)
        }
        throw SSHTunnelError.authenticationFailed(passwordFailure ?? failure.detail)
    }

    func publicKey(_ key: Key, passphrase: String?) throws {
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let traits = Self.traits(of: key.contents)
        if traits.isSecurityKey { throw SSHTunnelError.securityKeyUnsupported }
        if traits.isEncrypted, passphrase == nil { throw SSHTunnelError.passphraseRequired }

        guard let offered = try methodsOnOffer() else { return }
        guard offered.contains(Self.publicKeyMethod) else {
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
        guard let failure = try readFailure(of: Self.publicKeyMethod, rc: rc, offered: offered) else { return }
        throw SSHTunnelError.authenticationFailed(failure.detail)
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

    // The last error goes first: re-reading the list overwrites it. libssh2 never reads the
    // partial-success flag, so an accepted first step shows only as its method leaving the list.
    // nil when the session turned out to be signed in.
    private func readFailure(of method: String, rc: Int32, offered: [String]) throws -> Failure? {
        let detail = session.lastError() ?? "\(method) authentication failed (error \(rc))"
        Self.logger.debug("SSH \(method, privacy: .public) authentication failed (\(rc)): \(detail, privacy: .public)")

        let after: [String]
        switch offer() {
        case .authenticated: return nil
        case .methods(let methods): after = methods
        case .unavailable: after = []
        }

        if let remaining = SSHAuthMethods.remainingAfterPartialSuccess(of: method, before: offered, after: after) {
            throw SSHTunnelError.additionalFactorRequired(remaining)
        }
        return Failure(detail: detail, methodsAfter: after)
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
        defer { abstract.pointee = previous }

        return withExtendedLifetime(answers) {
            libssh2_userauth_keyboard_interactive_ex(session, username, UInt32(username.utf8.count)) { _, _, _, _, count, prompts, responses, slot in
                guard count > 0, let prompts, let responses, let context = slot?.pointee else { return }
                let answers = Unmanaged<KeyboardInteractiveAnswers>.fromOpaque(context).takeUnretainedValue()
                for index in 0 ..< Int(count) {
                    // libssh2 frees each response, so it has to come from the C heap.
                    let response = strdup(answers.answer(LibSSH2UserAuthSession.text(of: prompts[index])))
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
}
