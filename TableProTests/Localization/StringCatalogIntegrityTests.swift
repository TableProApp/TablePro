//
//  StringCatalogIntegrityTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A translation is data, so the compiler never reads it. A Turkish string that spells `%@` where the
/// source passes `%lld` still builds, ships, and then formats garbage or traps at runtime, and nobody
/// on the team reads Turkish closely enough to catch it in review. The catalogs carry more than 15,000
/// translated units across four languages, and both grow every release.
///
/// These are the rules the shipped catalogs already keep, measured across every unit in both of them
/// before this guard was written, so a failure here is a new defect rather than a pre-existing one.
/// Style choices that legitimately differ by language are deliberately not asserted: Chinese renders
/// terminal punctuation and ellipses full width, and 232 shipped translations pass two or more
/// arguments in plain `%@` order rather than positionally.
@Suite("String catalogs agree with their source strings")
struct StringCatalogIntegrityTests {
    @Test("Every translation consumes the arguments its source passes")
    func argumentsMatchSource() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits.compactMap { unit -> String? in
                let expected = FormatSpecifier.arguments(in: unit.source, substitutions: unit.sourceSubstitutions)
                let found = FormatSpecifier.parse(unit.value)
                let foundArguments = FormatSpecifier.arguments(in: unit.value, substitutions: unit.valueSubstitutions)
                guard !expected.isEmpty || !foundArguments.isEmpty else { return nil }
                if let complaint = Self.mismatch(expected: expected, found: found, foundArguments: foundArguments) {
                    return "\(unit.description): \(complaint)"
                }
                return nil
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A translation does not consume the same arguments as its source string. String(format:) \
            reads whatever the specifier names, so this formats the wrong value or crashes.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("No translation carries Apple's English-only inflection markup")
    func inflectionMarkupStaysInTheSource() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits
                .filter { $0.value.contains("^[") }
                .map(\.description)
        }

        #expect(
            offenders.isEmpty,
            """
            `^[noun](inflect: true)` is English grammar Foundation applies for the source language \
            only. Translations write the plain noun their own language needs.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("Shortcuts parameter tokens survive translation")
    func interpolationTokensSurvive() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits.compactMap { unit -> String? in
                let wanted = Self.interpolationTokens(in: unit.key)
                let found = Self.interpolationTokens(in: unit.value)
                guard wanted != found else { return nil }
                return "\(unit.description): has \(found.joined(separator: " ")), source has \(wanted.joined(separator: " "))"
            }
        }

        #expect(
            offenders.isEmpty,
            """
            `${name}` in an App Intents parameter summary is a parameter reference, not a word. \
            Shortcuts drops the summary when the token no longer resolves.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("A command that ends in an ellipsis keeps one in every language")
    func ellipsisSurvives() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits.compactMap { unit -> String? in
                let sourceEnds = Self.endsWithEllipsis(unit.key)
                guard sourceEnds != Self.endsWithEllipsis(unit.value) else { return nil }
                return "\(unit.description): source \(sourceEnds ? "has" : "has no") trailing ellipsis"
            }
        }

        #expect(
            offenders.isEmpty,
            """
            The trailing ellipsis is the platform's promise that a command opens something before it \
            acts. Either spelling is fine, and Chinese uses the single character, but it has to be there.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("A source that ends in a sentence mark keeps one in every language")
    func terminalPunctuationSurvives() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits.compactMap { unit -> String? in
                guard !Self.endsWithEllipsis(unit.key) else { return nil }
                guard let mark = Self.terminalMarks.first(where: { unit.key.hasSuffix($0.key) }) else { return nil }
                guard !mark.value.contains(where: { unit.value.hasSuffix($0) }) else { return nil }
                return "\(unit.description): source ends in \(mark.key)"
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A label that drops the source's sentence mark reads as a different kind of string. \
            The full-width forms Chinese uses count.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("No translation introduces an em dash its source does not have")
    func translationsAddNoEmDash() throws {
        let offenders = try StringCatalog.loadAll().flatMap { catalog in
            catalog.translatedUnits
                .filter { $0.value.contains(Self.emDash) && !$0.key.contains(Self.emDash) }
                .map(\.description)
        }

        #expect(
            offenders.isEmpty,
            """
            CLAUDE.md bans the em dash from anything a user reads. Nine source strings still carry one \
            and their translations may mirror it; nothing else may introduce one.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    static func mismatch(
        expected: [Int: String],
        found: [FormatSpecifier],
        foundArguments: [Int: String]
    ) -> String? {
        let indices = found.map(\.argumentIndex)
        if indices.contains(where: { $0 == nil }), indices.contains(where: { $0 != nil }) {
            return "mixes positional and plain specifiers"
        }
        guard Set(foundArguments.keys) == Set(expected.keys) else {
            let want = expected.isEmpty
                ? "no arguments"
                : expected.keys.sorted().map(String.init).joined(separator: ",")
            let got = foundArguments.isEmpty
                ? "none"
                : foundArguments.keys.sorted().map(String.init).joined(separator: ",")
            return "consumes \(got) but the source passes \(want)"
        }
        for index in expected.keys.sorted() {
            guard let want = expected[index], let got = foundArguments[index], want != got else { continue }
            return "argument \(index) is %\(got) but the source passes %\(want)"
        }
        return nil
    }

    static func interpolationTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var remainder = Substring(text)
        while let start = remainder.range(of: "${") {
            guard let end = remainder[start.upperBound...].firstIndex(of: "}") else { break }
            tokens.append(String(remainder[start.lowerBound ... end]))
            remainder = remainder[remainder.index(after: end)...]
        }
        return tokens.sorted()
    }

    static func endsWithEllipsis(_ text: String) -> Bool {
        text.hasSuffix("...") || text.hasSuffix("\u{2026}")
    }

    static let terminalMarks: [String: [String]] = [
        ":": [":", "\u{FF1A}"],
        "?": ["?", "\u{FF1F}"],
        ".": [".", "\u{3002}"],
    ]

    static let emDash = "\u{2014}"
}

/// Foundation has no public parser for printf specifiers, so the guard carries its own. It reads the
/// grammar `String(format:)` accepts: an optional `n$` argument index, flags, width, precision, a
/// length modifier, and the conversion character. `%%` is a literal percent and consumes no argument.
struct FormatSpecifier: Equatable, Sendable {
    let argumentIndex: Int?
    let type: String

    static func parse(_ text: String) -> [FormatSpecifier] {
        var specifiers: [FormatSpecifier] = []
        var characters = Array(text)
        var cursor = 0
        while cursor < characters.count {
            guard characters[cursor] == "%" else {
                cursor += 1
                continue
            }
            cursor += 1
            guard cursor < characters.count else { break }

            /// `%#@name@` is a substitution placeholder, not a printf specifier. Read as printf it
            /// looks like `%@` with a `#` flag, which is what made a plural translation report as
            /// mixing positional and plain specifiers.
            if characters[cursor] == "#", cursor + 1 < characters.count, characters[cursor + 1] == "@" {
                var scan = cursor + 2
                while scan < characters.count, characters[scan] != "@" {
                    scan += 1
                }
                guard scan < characters.count else { break }
                cursor = scan + 1
                continue
            }

            var index: Int?
            var digits = ""
            var lookahead = cursor
            while lookahead < characters.count, characters[lookahead].isNumber {
                digits.append(characters[lookahead])
                lookahead += 1
            }
            if !digits.isEmpty, lookahead < characters.count, characters[lookahead] == "$" {
                index = Int(digits)
                cursor = lookahead + 1
            }

            while cursor < characters.count, "-+ #0".contains(characters[cursor]) {
                cursor += 1
            }
            while cursor < characters.count, characters[cursor].isNumber {
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "." {
                cursor += 1
                while cursor < characters.count, characters[cursor].isNumber {
                    cursor += 1
                }
            }

            var length = ""
            for candidate in ["ll", "hh", "l", "h", "z", "q"] where length.isEmpty {
                let end = cursor + candidate.count
                if end <= characters.count, String(characters[cursor ..< end]) == candidate {
                    length = candidate
                    cursor = end
                }
            }

            guard cursor < characters.count else { break }
            let conversion = characters[cursor]
            cursor += 1
            guard conversion != "%" else { continue }
            guard "@diuUfFeEgGxXoscpaA".contains(conversion) else { continue }
            specifiers.append(FormatSpecifier(argumentIndex: index, type: length + String(conversion)))
        }
        return specifiers
    }

    /// The argument types a source string passes, in argument order.
    static func argumentTypes(in source: String) -> [String] {
        let specifiers = parse(source)
        guard !specifiers.isEmpty else { return [] }
        if specifiers.allSatisfy({ $0.argumentIndex != nil }) {
            var byIndex: [Int: String] = [:]
            for specifier in specifiers {
                byIndex[specifier.argumentIndex ?? 0] = specifier.type
            }
            return byIndex.keys.sorted().compactMap { byIndex[$0] }
        }
        return specifiers.map(\.type)
    }

    /// Which argument each side consumes, and as what.
    ///
    /// A `%#@name@` substitution is not a printf specifier and consumes no argument of its own; the
    /// `substitutions` block beside it says which argument it stands for and how that argument is
    /// spelled. Reading only the printf specifiers therefore under-counts a plural source by one
    /// argument, and reports every translation that inlines the plural as consuming an argument the
    /// source never passed.
    static func arguments(in text: String, substitutions: [Int: String]) -> [Int: String] {
        var arguments: [Int: String] = [:]
        for (position, specifier) in parse(text).enumerated() {
            arguments[specifier.argumentIndex ?? position + 1] = specifier.type
        }
        for (index, specifier) in substitutions {
            arguments[index] = specifier
        }
        return arguments
    }
}

struct StringCatalog {
    struct Unit {
        let catalog: String
        let language: String
        let key: String
        let source: String
        let value: String

        /// `argNum` to format specifier, for the `%#@name@` substitutions each side declares. A
        /// plural substitution consumes a real argument that no printf specifier spells out, so a
        /// side that inlines `%4$d` and a side that writes `%#@points@` pass the same arguments.
        let sourceSubstitutions: [Int: String]
        let valueSubstitutions: [Int: String]

        var description: String { "\(catalog):\(language): \"\(key)\" -> \"\(value)\"" }
    }

    let name: String
    private let strings: [String: Entry]
    private let sourceLanguage: String

    var translatedUnits: [Unit] {
        strings.sorted { $0.key < $1.key }.flatMap { key, entry -> [Unit] in
            let sourceLocalization = entry.localizations?[sourceLanguage]
            let source = sourceLocalization?.stringUnit?.value ?? key
            let sourceSubstitutions = sourceLocalization?.argumentSubstitutions ?? [:]
            return (entry.localizations ?? [:])
                .sorted { $0.key < $1.key }
                .filter { $0.key != sourceLanguage }
                .flatMap { language, localization -> [Unit] in
                    let plain = localization.stringUnit.map { [$0] } ?? []
                    let varied = (localization.variations ?? [:]).values
                        .flatMap(\.values)
                        .compactMap(\.stringUnit)
                    return (plain + varied)
                        .filter { $0.state == "translated" }
                        .map {
                            Unit(
                                catalog: name,
                                language: language,
                                key: key,
                                source: source,
                                value: $0.value,
                                sourceSubstitutions: sourceSubstitutions,
                                valueSubstitutions: localization.argumentSubstitutions
                            )
                        }
                }
        }
    }

    static func loadAll() throws -> [StringCatalog] {
        let root = try repoRoot()
        return try [
            ("TablePro", "TablePro/Resources/Localizable.xcstrings"),
            ("TableProMobile", "TableProMobile/TableProMobile/Localizable.xcstrings"),
        ].map { name, path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            return StringCatalog(name: name, strings: decoded.strings, sourceLanguage: decoded.sourceLanguage)
        }
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CatalogError.repoRootNotFound
    }

    private struct Payload: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: [String: [String: Variation]]?
        let substitutions: [String: Substitution]?

        var argumentSubstitutions: [Int: String] {
            (substitutions ?? [:]).values.reduce(into: [:]) { result, substitution in
                result[substitution.argNum] = substitution.formatSpecifier
            }
        }
    }

    struct Substitution: Decodable {
        let argNum: Int
        let formatSpecifier: String
    }

    struct Variation: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    enum CatalogError: Error {
        case repoRootNotFound
    }
}

@Suite("Format specifier parsing")
struct FormatSpecifierTests {
    @Test("A plain specifier carries no argument index")
    func plainSpecifier() {
        #expect(FormatSpecifier.parse("%@ rows") == [FormatSpecifier(argumentIndex: nil, type: "@")])
    }

    @Test("A length modifier is part of the type")
    func lengthModifier() {
        #expect(FormatSpecifier.parse("%lld of %d").map(\.type) == ["lld", "d"])
    }

    @Test("Width and precision are not the type")
    func widthAndPrecision() {
        #expect(FormatSpecifier.parse("%.3fms") == [FormatSpecifier(argumentIndex: nil, type: "f")])
        #expect(FormatSpecifier.parse("%-8.2f") == [FormatSpecifier(argumentIndex: nil, type: "f")])
    }

    @Test("A literal percent consumes no argument")
    func literalPercent() {
        #expect(FormatSpecifier.parse("100%% done").isEmpty)
        #expect(FormatSpecifier.parse("%1$lld%% slower").map(\.argumentIndex) == [1])
    }

    @Test("Positional specifiers report their index")
    func positionalSpecifiers() {
        let parsed = FormatSpecifier.parse("%2$@ on %1$@")
        #expect(parsed.map(\.argumentIndex) == [2, 1])
    }

    @Test("An argument used twice is one argument")
    func repeatedArgument() {
        #expect(FormatSpecifier.argumentTypes(in: "%1$@ owns %2$d items in %1$@") == ["@", "d"])
    }

    @Test("Argument types follow argument order, not written order")
    func typesFollowArgumentOrder() {
        #expect(FormatSpecifier.argumentTypes(in: "%2$lld of %1$@") == ["@", "lld"])
    }
}

@Suite("String catalog rule checks")
struct StringCatalogRuleTests {
    private static func complaint(
        source: String,
        sourceSubstitutions: [Int: String] = [:],
        value: String,
        valueSubstitutions: [Int: String] = [:]
    ) -> String? {
        StringCatalogIntegrityTests.mismatch(
            expected: FormatSpecifier.arguments(in: source, substitutions: sourceSubstitutions),
            found: FormatSpecifier.parse(value),
            foundArguments: FormatSpecifier.arguments(in: value, substitutions: valueSubstitutions)
        )
    }

    @Test("A reordered translation is fine when it stays positional")
    func reorderedPositionalPasses() {
        #expect(Self.complaint(source: "%1$@ on %2$@", value: "%2$@ üzerinde %1$@") == nil)
    }

    @Test("A dropped argument is caught")
    func droppedArgumentFails() {
        #expect(Self.complaint(source: "%1$@ on %2$@", value: "%1$@") != nil)
    }

    @Test("A retyped argument is caught")
    func retypedArgumentFails() {
        #expect(Self.complaint(source: "%lld rows", value: "%@ satır") != nil)
    }

    @Test("Mixing positional and plain specifiers is caught")
    func mixedStyleFails() {
        #expect(Self.complaint(source: "%1$@ on %2$@", value: "%1$@ üzerinde %@") != nil)
    }

    /// A plural source spells its count as `%#@points@` and declares the real argument beside it.
    /// A translation that inlines `%4$d` passes the same four arguments, and one that keeps its own
    /// substitution does too. Reading only the printf specifiers reported both as defects, which is
    /// six false alarms on the shipped catalog.
    @Test("A plural substitution counts as the argument it stands for")
    func pluralSubstitutionCountsAsItsArgument() {
        let source = "%1$@ chart of %2$@ by %3$@ with %#@points@"
        let substitutions = [4: "d"]

        #expect(Self.complaint(
            source: source,
            sourceSubstitutions: substitutions,
            value: "%3$@ ölçütüne göre %2$@ için %4$d noktalı %1$@ grafiği"
        ) == nil)
        #expect(Self.complaint(
            source: source,
            sourceSubstitutions: substitutions,
            value: "%3$@ 기준 %2$@의 %1$@ 차트, %#@points@",
            valueSubstitutions: substitutions
        ) == nil)
    }

    @Test("A translation that drops the plural argument is still caught")
    func droppedPluralArgumentFails() {
        #expect(Self.complaint(
            source: "%1$@ with %#@points@",
            sourceSubstitutions: [2: "d"],
            value: "%1$@"
        ) != nil)
    }

    @Test("A translation that retypes the plural argument is still caught")
    func retypedPluralArgumentFails() {
        #expect(Self.complaint(
            source: "%1$@ with %#@points@",
            sourceSubstitutions: [2: "d"],
            value: "%1$@ với %2$@"
        ) != nil)
    }

    @Test("Full-width punctuation counts as the sentence mark")
    func fullWidthPunctuationCounts() {
        let marks = StringCatalogIntegrityTests.terminalMarks
        #expect(marks["."]?.contains(where: { "已导入。".hasSuffix($0) }) == true)
        #expect(marks["?"]?.contains(where: { "確定嗎？".hasSuffix($0) }) == true)
    }

    @Test("Either ellipsis spelling satisfies the ellipsis rule")
    func eitherEllipsisSpellingPasses() {
        #expect(StringCatalogIntegrityTests.endsWithEllipsis("Open Quickly..."))
        #expect(StringCatalogIntegrityTests.endsWithEllipsis("快速打開…"))
        #expect(!StringCatalogIntegrityTests.endsWithEllipsis("Open Quickly"))
    }

    @Test("Interpolation tokens are compared as a set")
    func interpolationTokensAreCompared() {
        #expect(StringCatalogIntegrityTests.interpolationTokens(in: "Add a row to ${table}") == ["${table}"])
        #expect(StringCatalogIntegrityTests.interpolationTokens(in: "Thêm hàng vào ${table}") == ["${table}"])
        #expect(StringCatalogIntegrityTests.interpolationTokens(in: "no tokens").isEmpty)
    }
}
