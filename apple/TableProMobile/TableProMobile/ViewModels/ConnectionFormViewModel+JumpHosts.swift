import Foundation
import TableProModels

extension ConnectionFormViewModel {
    nonisolated enum JumpHostKeyStatus: Equatable, Sendable {
        case sameKey
        case ownKey
        case noKey
    }

    static var jumpHostKeysUnreadableMessage: String {
        String(localized: "The jump host keys on this device could not be read. Close the form and open it again to change them.")
    }

    var serverSignsInWithKey: Bool {
        sshAuthMethod.onDevice == .privateKey
    }

    var hasJumpHostWithoutHost: Bool {
        sshEnabled && jumpHosts.contains { !$0.hasHost }
    }

    var jumpHostCredentials: [UUID: JumpHostCredential] {
        guard sshEnabled else { return [:] }
        var credentials: [UUID: JumpHostCredential] = [:]
        for hop in jumpHosts {
            credentials[hop.id] = hop.credential
        }
        return credentials
    }

    // Save rewrites only these hops' entries and keeps those of hops another device added.
    var jumpHostIdsShown: Set<UUID> {
        let opening = existingConnection?.sshConfiguration?.jumpHosts.map(\.id) ?? []
        return Set(opening)
            .union(jumpHosts.map(\.id))
            .union(storedSecrets.jumpHostCredentials.keys)
    }

    func jumpHost(_ id: UUID) -> JumpHostDraft? {
        jumpHosts.first { $0.id == id }
    }

    func updateJumpHost(_ id: UUID, _ change: (inout JumpHostDraft) -> Void) {
        guard let index = jumpHosts.firstIndex(where: { $0.id == id }) else { return }
        change(&jumpHosts[index])
    }

    func keyStatus(of hop: JumpHostDraft) -> JumpHostKeyStatus {
        if hop.usesServerKey {
            return serverSignsInWithKey ? .sameKey : .noKey
        }
        return hop.keyContent.isEmpty ? .noKey : .ownKey
    }

    @discardableResult
    func addJumpHost() -> UUID {
        let hop = JumpHostDraft()
        jumpHosts.append(hop)
        return hop.id
    }

    func removeJumpHosts(atOffsets offsets: IndexSet) {
        var remaining = jumpHosts
        for index in offsets.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }
        jumpHosts = remaining
    }

    func moveJumpHosts(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { jumpHosts.indices.contains($0) }
        let moving = valid.map { jumpHosts[$0] }
        var remaining = jumpHosts
        for index in valid.sorted(by: >) {
            remaining.remove(at: index)
        }
        let insertion = min(destination - valid.filter { $0 < destination }.count, remaining.count)
        remaining.insert(contentsOf: moving, at: max(insertion, 0))
        jumpHosts = remaining
    }

    @discardableResult
    func importJumpHostKey(_ result: Result<[URL], any Error>, for id: UUID) -> Bool {
        let url: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return false }
            url = first
        case .failure(let error):
            jumpHostKeyFileError = error.localizedDescription
            return false
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            jumpHostKeyFileError = String(localized: "That file is not a text private key.")
            return false
        }
        updateJumpHost(id) { hop in
            hop.usesServerKey = false
            hop.keyContent = content
        }
        return true
    }

    func dismissJumpHostKeyFileError() {
        jumpHostKeyFileError = nil
    }
}
