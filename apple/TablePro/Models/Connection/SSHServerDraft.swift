import Foundation
import TableProSSHConfig
import TableProSSHTransport

extension SSHProfile {
    // user@host, plus :port when it is not the default; host alone when there is no user.
    var address: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        var address = trimmedUser.isEmpty ? trimmedHost : "\(trimmedUser)@\(trimmedHost)"
        if let port, port != 22 {
            address += ":\(String(port))"
        }
        return address
    }
}

enum SSHSecret: CaseIterable, Hashable, Sendable {
    case password
    case keyPassphrase
    case totpSecret
}

struct SSHServerDraft: Equatable, Sendable {
    var host = ""
    var port = ""
    var username = ""
    var authMethod: SSHAuthMethod = .password
    var password = ""
    var privateKeyPath = ""
    var keyPassphrase = ""
    var agentSocketOption: SSHAgentSocketOption = .systemDefault
    var customAgentSocketPath = ""
    var selectedConfigHost = ""
    var jumpHosts: [SSHJumpHost] = []
    var totpMode: TOTPMode = .none
    var totpSecret = ""
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits = 6
    var totpPeriod = 30

    init() {}

    init(profile: SSHProfile) {
        host = profile.host
        port = profile.port.map(String.init) ?? ""
        username = profile.username
        authMethod = profile.authMethod
        privateKeyPath = profile.privateKeyPath
        jumpHosts = profile.jumpHosts
        totpMode = profile.totpMode
        totpAlgorithm = profile.totpAlgorithm
        totpDigits = profile.totpDigits
        totpPeriod = profile.totpPeriod
        applyAgentSocketPath(profile.agentSocketPath)
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var portNumber: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    var portIsValid: Bool {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return Int(trimmed).map { (1...65_535).contains($0) } ?? false
    }

    var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if trimmedHost.isEmpty {
            issues.append(String(localized: "SSH host is required"))
        }
        if !portIsValid {
            issues.append(String(localized: "SSH port must be between 1 and 65535"))
        }
        if !jumpHosts.allSatisfy(\.isValid) {
            issues.append(String(localized: "Jump host configuration is invalid"))
        }
        return issues
    }

    func applies(_ secret: SSHSecret) -> Bool {
        switch secret {
        case .password: authMethod == .password || authMethod == .keyboardInteractive
        case .keyPassphrase: authMethod == .privateKey
        case .totpSecret: totpMode == .autoGenerate
        }
    }

    func value(of secret: SSHSecret) -> String {
        switch secret {
        case .password: password
        case .keyPassphrase: keyPassphrase
        case .totpSecret: totpSecret
        }
    }

    var filledSecrets: Set<SSHSecret> {
        Set(SSHSecret.allCases.filter { !value(of: $0).isEmpty })
    }

    mutating func setValue(_ value: String, of secret: SSHSecret) {
        switch secret {
        case .password: password = value
        case .keyPassphrase: keyPassphrase = value
        case .totpSecret: totpSecret = value
        }
    }

    func configuration() -> SSHConfiguration {
        SSHConfiguration(
            enabled: true,
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )
    }

    func apply(to profile: inout SSHProfile) {
        profile.host = trimmedHost
        profile.port = portNumber
        profile.username = trimmedUsername
        profile.authMethod = authMethod
        profile.privateKeyPath = privateKeyPath
        profile.agentSocketPath = resolvedAgentSocketPath
        profile.jumpHosts = jumpHosts
        profile.totpMode = totpMode
        profile.totpAlgorithm = totpAlgorithm
        profile.totpDigits = totpDigits
        profile.totpPeriod = totpPeriod
    }

    var testCredentials: SSHTunnelCredentials {
        SSHTunnelCredentials(
            sshPassword: password.isEmpty ? nil : password,
            keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
            totpSecret: totpSecret.isEmpty ? nil : totpSecret,
            keyboardInteractivePromptProvider: nil
        )
    }

    mutating func applyAgentSocketPath(_ socketPath: String) {
        let option = SSHAgentSocketOption(socketPath: socketPath)
        agentSocketOption = option
        customAgentSocketPath = option == .custom ? socketPath.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    // Picking a config host also points the server at it, in one write.
    mutating func selectConfigHost(_ configHost: String) {
        selectedConfigHost = configHost
        if !configHost.isEmpty {
            host = configHost
        }
    }

    mutating func addJumpHost() {
        jumpHosts.append(SSHJumpHost())
    }

    mutating func removeJumpHost(id: UUID) {
        jumpHosts.removeAll { $0.id == id }
    }

    mutating func moveJumpHost(id: UUID, by offset: Int) {
        guard let index = jumpHosts.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard jumpHosts.indices.contains(destination) else { return }
        jumpHosts.swapAt(index, destination)
    }
}
