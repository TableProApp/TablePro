//
//  SpringYamlExtractor.swift
//  TablePro
//

import Foundation

enum SpringYamlExtractor {
    static func extract(
        contents: String,
        relativePath: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ScannedConnectionCandidate] {
        for document in YamlMappingSupport.loadDocuments(contents) {
            guard let rawURL = value(in: document, path: ["spring", "datasource", "url"]) else {
                continue
            }
            let url = SpringPropertiesExtractor.resolvePlaceholders(rawURL, processEnvironment: processEnvironment)
            guard let parsed = ScannedConnectionURLBuilder.parse(url) else {
                continue
            }
            let username = value(in: document, path: ["spring", "datasource", "username"]).map {
                SpringPropertiesExtractor.resolvePlaceholders($0, processEnvironment: processEnvironment)
            } ?? ""
            let password = value(in: document, path: ["spring", "datasource", "password"]).map {
                SpringPropertiesExtractor.resolvePlaceholders($0, processEnvironment: processEnvironment)
            } ?? ""
            let merged = parsed.with(
                username: parsed.username.isEmpty ? username : nil,
                password: parsed.password.isEmpty ? password : nil
            )
            let candidate = ScannedConnectionCandidate(
                parsedURL: merged,
                sourceRelativePath: relativePath,
                sourceKey: "spring.datasource.url",
                kind: .springYaml,
                tier: .configFile
            )
            return [candidate]
        }
        return []
    }

    static func value(in document: [String: Any], path: [String]) -> String? {
        if let flattened = YamlMappingSupport.string(document[path.joined(separator: ".")]) {
            return flattened
        }
        var current: [String: Any] = document
        for (offset, key) in path.enumerated() {
            let isLast = offset == path.count - 1
            if isLast {
                return YamlMappingSupport.string(current[key])
            }
            guard let nested = YamlMappingSupport.mapping(current[key]) else {
                let remainder = path[offset...].joined(separator: ".")
                return YamlMappingSupport.string(current[remainder])
            }
            current = nested
        }
        return nil
    }
}
