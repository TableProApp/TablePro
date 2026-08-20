//
//  BeancountIncludeResolver.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountSourceGraph: Sendable {
    let sourceFiles: [URL]
    let watchedDirectories: [URL]
    let reloadDependencies: [URL]
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

private struct BeancountDocumentDeclaration {
    let path: String
    let sourceDirectory: URL
}

final class BeancountIncludeResolver {
    private static let maximumSymbolicLinkDepth = 32

    private var visited: Set<URL> = []
    private var activeStack: Set<URL> = []
    private var sourceFiles: [URL] = []
    private var watchedDirectories: Set<URL> = []
    private var documentDeclarations: [BeancountDocumentDeclaration] = []
    private var documentRootPaths: [String] = []
    private var mainDirectory = URL(fileURLWithPath: "/")

    func resolve(fileURL: URL) throws -> BeancountSourceGraph {
        visited.removeAll()
        activeStack.removeAll()
        sourceFiles.removeAll()
        watchedDirectories.removeAll()
        documentDeclarations.removeAll()
        documentRootPaths.removeAll()

        let mainFile = fileURL.standardizedFileURL
        mainDirectory = mainFile.deletingLastPathComponent()
        try resolveFile(mainFile)

        let documentRoots = resolvedDocumentRoots()
        let documentFiles = resolvedDocumentFiles(documentRoots: documentRoots)
        let dependencies = Set(sourceFiles)
            .union(watchedDirectories)
            .union(documentFiles)

        return BeancountSourceGraph(
            sourceFiles: sourceFiles,
            watchedDirectories: watchedDirectories.sorted { $0.path < $1.path },
            reloadDependencies: dependencies.sorted { $0.path < $1.path }
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
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            let quotedValues = quotedStrings(in: line)
            let directive = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first

            if directive == "include", let includePath = quotedValues.first {
                let includeURLs = try resolveIncludeURLs(
                    includePath,
                    relativeTo: normalized.deletingLastPathComponent()
                )
                for includeURL in includeURLs {
                    try resolveFile(includeURL)
                }
            } else if directive == "option",
                      quotedValues.count >= 2,
                      quotedValues[0] == "documents" {
                documentRootPaths.append(quotedValues[1])
            } else if isDocumentDirective(line), let documentPath = quotedValues.first {
                documentDeclarations.append(
                    BeancountDocumentDeclaration(
                        path: documentPath,
                        sourceDirectory: normalized.deletingLastPathComponent()
                    )
                )
            }
        }
    }

    private func resolvedDocumentRoots() -> [URL] {
        Set(documentRootPaths.map { path in
            resolvePath(path, relativeTo: mainDirectory)
        }).sorted { $0.path < $1.path }
    }

    private func resolvedDocumentFiles(documentRoots: [URL]) -> Set<URL> {
        documentDeclarations.reduce(into: Set<URL>()) { files, declaration in
            if NSString(string: declaration.path).isAbsolutePath {
                files.formUnion(
                    documentFileDependencies(
                        for: URL(fileURLWithPath: declaration.path).standardizedFileURL
                    )
                )
            } else {
                files.formUnion(
                    documentFileDependencies(
                        for: resolvePath(declaration.path, relativeTo: declaration.sourceDirectory)
                    )
                )
                for root in documentRoots {
                    files.formUnion(
                        documentFileDependencies(for: resolvePath(declaration.path, relativeTo: root))
                    )
                }
            }
        }
    }

    private func documentFileDependencies(for file: URL) -> Set<URL> {
        var dependencies: Set<URL> = [file.standardizedFileURL]
        var candidate = file.standardizedFileURL

        for _ in 0..<Self.maximumSymbolicLinkDepth {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else {
                break
            }
            let destinationURL: URL
            if NSString(string: destination).isAbsolutePath {
                destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                destinationURL = candidate.deletingLastPathComponent()
                    .appendingPathComponent(destination)
                    .standardizedFileURL
            }
            guard dependencies.insert(destinationURL).inserted else { break }
            candidate = destinationURL
        }

        dependencies.insert(file.resolvingSymlinksInPath().standardizedFileURL)
        return dependencies
    }

    private func isDocumentDirective(_ line: String) -> Bool {
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, fields[1] == "document" else { return false }

        let dateParts = fields[0].split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "-" || $0 == "/" }
        )
        guard dateParts.count == 3,
              dateParts[0].count == 4,
              (1...2).contains(dateParts[1].count),
              (1...2).contains(dateParts[2].count) else {
            return false
        }
        return dateParts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private func resolveIncludeURLs(_ includePath: String, relativeTo directory: URL) throws -> [URL] {
        guard containsGlobPattern(includePath) else {
            return [resolvePath(includePath, relativeTo: directory)]
        }

        let patternURL = resolvePath(includePath, relativeTo: directory)
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

    private func resolvePath(_ path: String, relativeTo directory: URL) -> URL {
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return directory.appendingPathComponent(path).standardizedFileURL
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

    private func quotedStrings(in line: String) -> [String] {
        var values: [String] = []
        var inQuote = false
        var isEscaped = false
        var current = ""

        for character in line {
            if isEscaped {
                switch character {
                case "b": current.append("\u{08}")
                case "f": current.append("\u{0C}")
                case "n": current.append("\n")
                case "r": current.append("\r")
                case "t": current.append("\t")
                default: current.append(character)
                }
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                if inQuote {
                    values.append(current)
                    current = ""
                }
                inQuote.toggle()
                continue
            }
            if inQuote {
                current.append(character)
            }
        }

        return values
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
