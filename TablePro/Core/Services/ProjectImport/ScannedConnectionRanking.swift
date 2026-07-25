//
//  ScannedConnectionRanking.swift
//  TablePro
//

import Foundation

enum ScannedConnectionRanking {
    static func rankAndDeduplicate(_ candidates: [ScannedConnectionCandidate]) -> [ScannedConnectionCandidate] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.tier != rhs.tier {
                return lhs.tier < rhs.tier
            }
            if lhs.sourceRelativePath != rhs.sourceRelativePath {
                return lhs.sourceRelativePath < rhs.sourceRelativePath
            }
            return lhs.sourceKey < rhs.sourceKey
        }
        var seen: Set<String> = []
        var result: [ScannedConnectionCandidate] = []
        for candidate in ordered {
            let key = identity(of: candidate)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(candidate)
        }
        return result
    }

    static func identity(of candidate: ScannedConnectionCandidate) -> String {
        let parsed = candidate.parsedURL
        return [
            parsed.type.rawValue,
            parsed.host.lowercased(),
            String(parsed.port ?? parsed.type.defaultPort),
            parsed.database.lowercased(),
            parsed.username.lowercased(),
        ].joined(separator: "\u{1F}")
    }
}
