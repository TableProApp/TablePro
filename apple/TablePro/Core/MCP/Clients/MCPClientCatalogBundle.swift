import Foundation
import os
import TableProMCPClients

enum MCPClientCatalogBundle {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPClientCatalog")

    static let shared: MCPClientCatalog? = load(from: .main)

    static func load(from bundle: Bundle) -> MCPClientCatalog? {
        guard let url = bundle.url(forResource: "clients", withExtension: "json") else {
            logger.error("The app bundle has no clients.json")
            return nil
        }
        do {
            return try MCPClientCatalog.decode(Data(contentsOf: url))
        } catch {
            logger.error("clients.json could not be read: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }
}

struct MCPClientSessionSighting: Equatable, Sendable {
    let id: String
    let clientInfoName: String
    // The client's clientInfo title when it sent one, such as "Codex", else its name.
    let displayName: String
    let tokenName: String?

    init(id: String, clientInfoName: String, displayName: String? = nil, tokenName: String?) {
        self.id = id
        self.clientInfoName = clientInfoName
        self.displayName = displayName ?? clientInfoName
        self.tokenName = tokenName
    }
}

extension MCPClientSessionSighting {
    init(_ snapshot: MCPServerManager.SessionSnapshot) {
        self.init(
            id: snapshot.id,
            clientInfoName: snapshot.clientInfoName ?? snapshot.clientName,
            displayName: snapshot.clientName,
            tokenName: snapshot.tokenName
        )
    }
}

extension MCPClientCatalog {
    // The in-app Claude Agent runs the claude CLI, which names itself Claude Code; that session is TablePro's own.
    func clients(forSessionNamed clientInfoName: String, tokenName: String?) -> [MCPClientDefinition] {
        guard tokenName != MCPTokenStore.claudeAgentTokenName else { return [] }
        return clients(matchingClientInfoName: clientInfoName)
    }

    // ChatGPT and Codex CLI send one clientInfo name: the session is the one of them found on this Mac, else neither.
    func client(forSessionNamed clientInfoName: String, tokenName: String?, detected: Set<String>) -> MCPClientDefinition? {
        guard tokenName != MCPTokenStore.claudeAgentTokenName else { return nil }
        return client(matchingClientInfoName: clientInfoName, detected: detected)
    }

    // The rows a session lights: its own client, or every row it could be when the Mac cannot tell them apart.
    func clientIDs(forSessionNamed clientInfoName: String, tokenName: String?, detected: Set<String>) -> Set<String> {
        if let client = client(forSessionNamed: clientInfoName, tokenName: tokenName, detected: detected) {
            return [client.id]
        }
        return Set(clients(forSessionNamed: clientInfoName, tokenName: tokenName).map(\.id))
    }

    // An icon is still right when every client the session could be shares it, as ChatGPT and Codex CLI do.
    func iconSlug(forSessionNamed clientInfoName: String, tokenName: String?, detected: Set<String>) -> String? {
        if let client = client(forSessionNamed: clientInfoName, tokenName: tokenName, detected: detected) {
            return client.icon
        }
        let icons = Set(clients(forSessionNamed: clientInfoName, tokenName: tokenName).map(\.icon))
        return icons.count == 1 ? icons.first : nil
    }

    // The clients whose sessions only detection can tell apart.
    func ambiguousClientIDs(forSessionsNamed sessions: [(clientInfoName: String, tokenName: String?)]) -> Set<String> {
        var ids: Set<String> = []
        for session in sessions {
            let candidates = clients(forSessionNamed: session.clientInfoName, tokenName: session.tokenName)
            if candidates.count > 1 {
                ids.formUnion(candidates.map(\.id))
            }
        }
        return ids
    }
}
