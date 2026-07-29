//
//  SpringPropertiesExtractor.swift
//  TablePro
//

import Foundation

enum SpringPropertiesExtractor {
    static func extract(
        contents: String,
        relativePath: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ScannedConnectionCandidate] {
        let properties = parse(contents)
        guard let rawURL = properties["spring.datasource.url"] else {
            return []
        }
        let url = resolvePlaceholders(rawURL, processEnvironment: processEnvironment)
        guard let parsed = ScannedConnectionURLBuilder.parse(url) else {
            return []
        }
        let username = properties["spring.datasource.username"].map {
            resolvePlaceholders($0, processEnvironment: processEnvironment)
        } ?? ""
        let password = properties["spring.datasource.password"].map {
            resolvePlaceholders($0, processEnvironment: processEnvironment)
        } ?? ""
        let merged = parsed.with(
            username: parsed.username.isEmpty ? username : nil,
            password: parsed.password.isEmpty ? password : nil
        )
        let candidate = ScannedConnectionCandidate(
            parsedURL: merged,
            sourceRelativePath: relativePath,
            sourceKey: "spring.datasource.url",
            kind: .springProperties,
            tier: .configFile
        )
        return [candidate]
    }

    static func parse(_ contents: String) -> [String: String] {
        var properties: [String: String] = [:]
        var pending = ""
        for rawLine in DotenvParser.normalize(contents).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if pending.isEmpty, line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") {
                continue
            }
            if line.hasSuffix("\\") {
                pending += String(line.dropLast())
                continue
            }
            let full = pending + line
            pending = ""
            guard let pair = splitPair(full) else {
                continue
            }
            properties[pair.key] = pair.value
        }
        return properties
    }

    private static func splitPair(_ line: String) -> (key: String, value: String)? {
        let separators: Set<Character> = ["=", ":"]
        guard let index = line.firstIndex(where: { separators.contains($0) }) else {
            return nil
        }
        let key = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return nil
        }
        return (key, value)
    }

    static func resolvePlaceholders(_ value: String, processEnvironment: [String: String]) -> String {
        guard value.contains("${") else {
            return value
        }
        var result = ""
        var remainder = Substring(value)
        while let open = remainder.range(of: "${") {
            result += remainder[remainder.startIndex..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "}") else {
                result += remainder[open.lowerBound...]
                return result
            }
            let reference = String(afterOpen[afterOpen.startIndex..<close])
            result += resolveReference(reference, processEnvironment: processEnvironment)
            remainder = afterOpen[afterOpen.index(after: close)...]
        }
        result += remainder
        return result
    }

    private static func resolveReference(_ reference: String, processEnvironment: [String: String]) -> String {
        guard let colon = reference.firstIndex(of: ":") else {
            return processEnvironment[reference] ?? "${\(reference)}"
        }
        let name = String(reference[reference.startIndex..<colon])
        var fallback = String(reference[reference.index(after: colon)...])
        if fallback.hasPrefix("-") {
            fallback.removeFirst()
        }
        return processEnvironment[name] ?? fallback
    }
}
