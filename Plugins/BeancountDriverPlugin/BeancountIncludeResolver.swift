//
//  BeancountIncludeResolver.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountSourceGraph: Sendable {
    let sourceFiles: [URL]
    let watchedDirectories: [URL]
}

enum BeancountResolverError: LocalizedError {
    case includeCycle(String)
    case unreadable(URL, Error)

    var errorDescription: String? {
        switch self {
        case .includeCycle(let path):
            return String(format: String(localized: "Beancount include cycle detected at %@"), path)
        case .unreadable(let url, let error):
            return String(format: String(localized: "Could not read %@: %@"), url.path, error.localizedDescription)
        }
    }
}

final class BeancountIncludeResolver {
    private var visited: Set<URL> = []
    private var activeStack: Set<URL> = []
    private var sourceFiles: [URL] = []
    private var watchedDirectories: Set<URL> = []

    func resolve(fileURL: URL) throws -> BeancountSourceGraph {
        visited.removeAll()
        activeStack.removeAll()
        sourceFiles.removeAll()
        watchedDirectories.removeAll()

        try resolveFile(fileURL.standardizedFileURL)

        return BeancountSourceGraph(
            sourceFiles: sourceFiles,
            watchedDirectories: watchedDirectories.sorted { $0.path < $1.path }
        )
    }

    private func resolveFile(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        if activeStack.contains(normalized) {
            throw BeancountResolverError.includeCycle(normalized.path)
        }
        guard !visited.contains(normalized) else { return }

        activeStack.insert(normalized)
        defer { activeStack.remove(normalized) }

        let contents: String
        do {
            contents = try String(contentsOf: normalized, encoding: .utf8)
        } catch {
            throw BeancountResolverError.unreadable(normalized, error)
        }

        visited.insert(normalized)
        sourceFiles.append(normalized)

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("include "), let includePath = quotedString(in: trimmed) else { continue }
            let includeURLs = try resolveIncludeURLs(
                includePath,
                relativeTo: normalized.deletingLastPathComponent()
            )
            for includeURL in includeURLs {
                try resolveFile(includeURL)
            }
        }
    }

    private func resolveIncludeURLs(_ includePath: String, relativeTo directory: URL) throws -> [URL] {
        guard containsGlobPattern(includePath) else {
            return [resolveIncludeURL(includePath, relativeTo: directory)]
        }

        let patternURL = resolveIncludeURL(includePath, relativeTo: directory)
        let patternPath = patternURL.path
        let searchRoot = globSearchRoot(for: patternPath)
        guard searchRoot.path != "/" else { return [] }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: searchRoot.path) else {
            watchedDirectories.insert(existingWatchDirectory(for: searchRoot))
            return []
        }
        watchedDirectories.insert(searchRoot)

        let regex = try NSRegularExpression(pattern: globRegex(for: patternPath))
        let enumerator = fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var matches: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                watchedDirectories.insert(candidate.standardizedFileURL)
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let path = candidate.standardizedFileURL.path
            let range = NSRange(location: 0, length: (path as NSString).length)
            if regex.firstMatch(in: path, range: range) != nil {
                matches.append(candidate.standardizedFileURL)
            }
        }

        return matches.sorted { $0.path < $1.path }
    }

    private func resolveIncludeURL(_ includePath: String, relativeTo directory: URL) -> URL {
        if includePath.hasPrefix("/") {
            return URL(fileURLWithPath: includePath).standardizedFileURL
        }
        return directory.appendingPathComponent(includePath).standardizedFileURL
    }

    private func containsGlobPattern(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    private func globSearchRoot(for patternPath: String) -> URL {
        let components = (patternPath as NSString).pathComponents
        let prefix = components.prefix { !containsGlobPattern($0) }
        let rootPath = NSString.path(withComponents: Array(prefix))
        return URL(fileURLWithPath: rootPath.isEmpty ? "/" : rootPath).standardizedFileURL
    }

    private func existingWatchDirectory(for missingDirectory: URL) -> URL {
        var candidate = missingDirectory.standardizedFileURL
        let fileManager = FileManager.default
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/")
    }

    private func globRegex(for patternPath: String) -> String {
        let characters = Array(patternPath)
        var regex = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                let nextIndex = index + 1
                if nextIndex < characters.count, characters[nextIndex] == "*" {
                    let slashIndex = index + 2
                    if slashIndex < characters.count, characters[slashIndex] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                } else {
                    regex += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                regex += "[^/]"
                index += 1
            } else if character == "[" {
                let start = index
                index += 1
                while index < characters.count, characters[index] != "]" {
                    index += 1
                }
                if index < characters.count {
                    regex += String(characters[start...index])
                    index += 1
                } else {
                    regex += NSRegularExpression.escapedPattern(for: String(character))
                }
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }

        return regex + "$"
    }

    private func quotedString(in line: String) -> String? {
        var inQuote = false
        var isEscaped = false
        var current = ""

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                if inQuote {
                    return current
                }
                inQuote = true
                continue
            }
            if inQuote {
                current.append(character)
            }
        }

        return nil
    }

    private func stripComment(_ line: String) -> String {
        var inQuote = false
        var isEscaped = false
        var result = ""
        for character in line {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                inQuote.toggle()
            }
            if character == ";" && !inQuote {
                break
            }
            result.append(character)
        }
        return result
    }
}
