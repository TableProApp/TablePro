//
//  BeancountLedgerParser.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountLedger: Sendable {
    let transactions: [BeancountTransaction]
    let postings: [BeancountPosting]
    let accounts: [BeancountAccount]
    let prices: [BeancountPrice]
    let balances: [BeancountBalance]
    let sourceFiles: [URL]
    let watchedDirectories: [URL]
}

struct BeancountTransaction: Sendable {
    let id: Int
    let date: String
    let flag: String
    let payee: String?
    let narration: String?
    let sourceFile: URL
    let line: Int
}

struct BeancountPosting: Sendable {
    let id: Int
    let transactionId: Int
    let date: String
    let account: String
    let amount: String?
    let commodity: String?
    let sourceFile: URL
    let line: Int
}

struct BeancountAccount: Sendable {
    let name: String
    let openDate: String
    let currencies: String?
    let sourceFile: URL
    let line: Int
}

struct BeancountPrice: Sendable {
    let id: Int
    let date: String
    let commodity: String
    let amount: String
    let currency: String
    let sourceFile: URL
    let line: Int
}

struct BeancountBalance: Sendable {
    let id: Int
    let date: String
    let account: String
    let amount: String
    let commodity: String
    let sourceFile: URL
    let line: Int
}

enum BeancountParserError: LocalizedError {
    case includeCycle(String)
    case unreadable(URL, Error)

    var errorDescription: String? {
        switch self {
        case .includeCycle(let path):
            return "Beancount include cycle detected at \(path)"
        case .unreadable(let url, let error):
            return "Could not read \(url.path): \(error.localizedDescription)"
        }
    }
}

final class BeancountLedgerParser {
    private var visited: Set<URL> = []
    private var activeStack: Set<URL> = []
    private var sourceFiles: [URL] = []
    private var transactions: [BeancountTransaction] = []
    private var postings: [BeancountPosting] = []
    private var accountsByName: [String: BeancountAccount] = [:]
    private var prices: [BeancountPrice] = []
    private var balances: [BeancountBalance] = []
    private var watchedDirectories: Set<URL> = []

    func parse(fileURL: URL) throws -> BeancountLedger {
        visited.removeAll()
        activeStack.removeAll()
        sourceFiles.removeAll()
        transactions.removeAll()
        postings.removeAll()
        accountsByName.removeAll()
        prices.removeAll()
        balances.removeAll()
        watchedDirectories.removeAll()

        try parseFile(fileURL.standardizedFileURL)

        return BeancountLedger(
            transactions: transactions,
            postings: postings,
            accounts: accountsByName.values.sorted { $0.name < $1.name },
            prices: prices,
            balances: balances,
            sourceFiles: sourceFiles,
            watchedDirectories: watchedDirectories.sorted { $0.path < $1.path }
        )
    }

    private func parseFile(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        if activeStack.contains(normalized) {
            throw BeancountParserError.includeCycle(normalized.path)
        }
        guard !visited.contains(normalized) else { return }

        activeStack.insert(normalized)
        defer { activeStack.remove(normalized) }

        let contents: String
        do {
            contents = try String(contentsOf: normalized, encoding: .utf8)
        } catch {
            throw BeancountParserError.unreadable(normalized, error)
        }

        visited.insert(normalized)
        sourceFiles.append(normalized)

        let lines = contents.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            let rawLine = lines[index]
            let trimmed = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            guard !trimmed.isEmpty else { continue }

            if let includePath = parseInclude(trimmed) {
                let includeURLs = try resolveIncludeURLs(
                    includePath,
                    relativeTo: normalized.deletingLastPathComponent()
                )
                for includeURL in includeURLs {
                    try parseFile(includeURL)
                }
                continue
            }

            guard let date = parseDatePrefix(trimmed) else { continue }
            let remainder = String(trimmed.dropFirst(11))

            if remainder.hasPrefix("open ") {
                parseOpen(remainder: remainder, date: date, sourceFile: normalized, line: lineNumber)
            } else if remainder.hasPrefix("price ") {
                parsePrice(remainder: remainder, date: date, sourceFile: normalized, line: lineNumber)
            } else if remainder.hasPrefix("balance ") {
                parseBalance(remainder: remainder, date: date, sourceFile: normalized, line: lineNumber)
            } else if let flag = remainder.first, flag == "*" || flag == "!" {
                let transactionId = transactions.count + 1
                let transaction = parseTransaction(
                    id: transactionId,
                    remainder: remainder,
                    date: date,
                    sourceFile: normalized,
                    line: lineNumber
                )
                transactions.append(transaction)

                var postingIndex = index + 1
                while postingIndex < lines.count {
                    let postingLine = lines[postingIndex]
                    guard postingLine.first?.isWhitespace == true else { break }
                    if let posting = parsePosting(
                        postingLine,
                        id: postings.count + 1,
                        transactionId: transactionId,
                        date: date,
                        sourceFile: normalized,
                        line: postingIndex + 1
                    ) {
                        postings.append(posting)
                    }
                    postingIndex += 1
                }
                index = postingIndex - 1
            }
        }
    }

    private func parseInclude(_ line: String) -> String? {
        guard line.hasPrefix("include ") else { return nil }
        return quotedStrings(in: line).first
    }

    private func resolveIncludeURLs(_ includePath: String, relativeTo directory: URL) throws -> [URL] {
        guard containsGlobPattern(includePath) else {
            return [resolveIncludeURL(includePath, relativeTo: directory)]
        }

        let patternURL = resolveIncludeURL(includePath, relativeTo: directory)
        let patternPath = patternURL.path
        let searchRoot = globSearchRoot(for: patternPath)
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

    private func parseOpen(remainder: String, date: String, sourceFile: URL, line: Int) {
        let parts = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2 else { return }
        let account = parts[1]
        let currencies = parts.dropFirst(2).joined(separator: " ")
        accountsByName[account] = BeancountAccount(
            name: account,
            openDate: date,
            currencies: currencies.isEmpty ? nil : currencies,
            sourceFile: sourceFile,
            line: line
        )
    }

    private func parsePrice(remainder: String, date: String, sourceFile: URL, line: Int) {
        let parts = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4 else { return }
        prices.append(BeancountPrice(
            id: prices.count + 1,
            date: date,
            commodity: parts[1],
            amount: parts[2],
            currency: parts[3],
            sourceFile: sourceFile,
            line: line
        ))
    }

    private func parseBalance(remainder: String, date: String, sourceFile: URL, line: Int) {
        let parts = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4 else { return }
        balances.append(BeancountBalance(
            id: balances.count + 1,
            date: date,
            account: parts[1],
            amount: parts[2],
            commodity: parts[3],
            sourceFile: sourceFile,
            line: line
        ))
    }

    private func parseTransaction(
        id: Int,
        remainder: String,
        date: String,
        sourceFile: URL,
        line: Int
    ) -> BeancountTransaction {
        let quoted = quotedStrings(in: remainder)
        return BeancountTransaction(
            id: id,
            date: date,
            flag: String(remainder.prefix(1)),
            payee: quoted.count >= 2 ? quoted[0] : nil,
            narration: quoted.count >= 2 ? quoted[1] : quoted.first,
            sourceFile: sourceFile,
            line: line
        )
    }

    private func parsePosting(
        _ rawLine: String,
        id: Int,
        transactionId: Int,
        date: String,
        sourceFile: URL,
        line: Int
    ) -> BeancountPosting? {
        let trimmed = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#") else { return nil }

        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let account = parts.first, isAccountName(account) else { return nil }
        let amount = parts.count >= 2 ? parts[1] : nil
        let commodity = parts.count >= 3 ? parts[2] : nil

        return BeancountPosting(
            id: id,
            transactionId: transactionId,
            date: date,
            account: account,
            amount: amount,
            commodity: commodity,
            sourceFile: sourceFile,
            line: line
        )
    }

    private func isAccountName(_ value: String) -> Bool {
        guard value.contains(":"), !value.hasSuffix(":") else { return false }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }

        let allowedSymbols = CharacterSet(charactersIn: "-_")
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first,
                  CharacterSet.uppercaseLetters.contains(first) else {
                return false
            }
            return component.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || allowedSymbols.contains(scalar)
            }
        }
    }

    private func parseDatePrefix(_ line: String) -> String? {
        guard line.count >= 11 else { return nil }
        let prefix = String(line.prefix(10))
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        guard prefix.range(of: pattern, options: .regularExpression) != nil,
              line.dropFirst(10).first?.isWhitespace == true else {
            return nil
        }
        return prefix
    }

    private func quotedStrings(in line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuote = false
        var isEscaped = false

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
