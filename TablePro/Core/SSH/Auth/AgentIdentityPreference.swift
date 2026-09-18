//
//  AgentIdentityPreference.swift
//  TablePro
//

import Foundation

/// Which of an agent's keys to offer, and in what order.
///
/// An agent that holds one key per server holds a lot of keys, and `MaxAuthTries` defaults to 6,
/// so offering them in agent order disconnects long before the right one is reached. OpenSSH's
/// `pubkey_prepare()` states the order it uses:
///
///     1. certificates listed in the config file
///     2. agent keys that are found in the config file
///     3. other agent keys
///
/// and it builds group 3 only under `!options.identities_only`. That is the whole rule, and
/// keeping it here rather than in the offer loop is what makes it testable without an agent or a
/// server.
internal enum AgentIdentityPreference {
    /// Indices into `agentIdentities`, in the order they should be offered.
    ///
    /// An empty `preferred` list means nothing named an identity, so the agent's own order stands
    /// and every key is offered, exactly as before there was a preference at all.
    static func offerOrder(
        agentIdentities: [Data],
        preferred: [SSHPublicKeyBlob],
        identitiesOnly: Bool
    ) -> [Int] {
        guard !preferred.isEmpty else { return Array(agentIdentities.indices) }

        let ordered = preferred.filter(\.isCertificate) + preferred.filter { !$0.isCertificate }
        var matched: [Int] = []
        var taken = Set<Int>()

        for identity in ordered {
            let match = agentIdentities.indices.first { index in
                !taken.contains(index) && agentIdentities[index] == identity.blob
            }
            guard let match else { continue }
            taken.insert(match)
            matched.append(match)
        }

        guard !identitiesOnly else { return matched }
        return matched + agentIdentities.indices.filter { !taken.contains($0) }
    }
}
