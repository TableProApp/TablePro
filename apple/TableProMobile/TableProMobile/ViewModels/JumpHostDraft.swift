import Foundation
import TableProModels

nonisolated struct JumpHostDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var host: String
    var port: String
    var username: String
    var usesServerKey = false
    var keyContent = ""
    var keyPassphrase = ""

    init(id: UUID = UUID(), host: String = "", port: String = "", username: String = "") {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
    }

    init(hop: SSHJumpHost) {
        self.init(id: hop.id, host: hop.host, port: hop.port.map(String.init) ?? "", username: hop.username)
    }

    var edit: ConnectionFormEdits.JumpHostEdit {
        ConnectionFormEdits.JumpHostEdit(id: id, host: host, port: Int(port), username: username)
    }

    var credential: JumpHostCredential? {
        if usesServerKey { return .sshServerKey }
        guard !keyContent.isEmpty else { return nil }
        return .privateKey(key: keyContent, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
    }

    var hasHost: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    mutating func adopt(_ credential: JumpHostCredential) {
        switch credential {
        case .sshServerKey:
            usesServerKey = true
        case .privateKey(let key, let passphrase):
            usesServerKey = false
            keyContent = key
            keyPassphrase = passphrase ?? ""
        }
    }
}
