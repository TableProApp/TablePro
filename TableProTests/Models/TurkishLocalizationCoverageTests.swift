//
//  TurkishLocalizationCoverageTests.swift
//  TableProTests
//
//  A catalog entry marked `translated` whose value is still the English source is a false claim,
//  and it hides the gap from everyone: the string ships in English, the state says otherwise, and
//  no tooling flags it. Turkish carried 285 of these while Vietnamese carried 59 and Korean 17, so
//  it was not an even spread of terms that happen to be identical.
//

import Foundation
import Testing

@Suite("Turkish localization coverage")
struct TurkishLocalizationCoverageTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// Entries whose Turkish is correctly the same as the English. Brand names, protocol and
    /// credential field names, SQL literals, date-format samples, and strings made only of format
    /// specifiers. `CLAUDE.md` says not to localize technical terms, so these are the exception the
    /// check is built around rather than a backlog.
    private static let identicalByDesign: Set<String> = [
        "%1$@ (%2$@)", "%1$@ +%2$lld", "%1$@: %2$@", "%1$@ · %2$@", "%@ %@", "%@ (%@@%@)", "%@ (%lld/%lld)",
        "%@ → %@.%@", "%@. %@", "%@. %@. %@", "%@: %@, %@", "%lld / %lld", "%lld / ~%lld",
        "(%lld %@)", ", %@", "<1 ms", "db %d", "v%@ · %@",
        "API Token", "Access Key ID", "Account ID", "Application Default Credentials",
        "Claude Code", "Claude Desktop", "Client ID", "Client Secret", "ISO 8601 (2024-12-31 23:59:59)",
        "JSON: %@", "Kerberos Principal", "Microsoft Entra ID", "MySQL, PostgreSQL & SQLite",
        "OAuth Client ID", "OAuth Client Secret", "PHP: %@", "Plan: %@", "Raw SQL",
        "SELECT * FROM users WHERE id = 42;", "SOCKS Proxy", "SSH Host", "SSH Port", "SSH User",
        "Secret Access Key", "Session Token", "Set DEFAULT", "Set EMPTY", "Set NULL",
        "TOTP Secret", "TablePro Website", "UPDATE Statement(s)",
        "US Long (12/31/2024 11:59:59 PM)", "US Short (12/31/2024)", "is NULL", "is not NULL"
    ]

    private static func catalogStrings() throws -> [String: [String: Any]] {
        let url = repositoryRoot.appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let parsed = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require((parsed as? [String: Any])?["strings"] as? [String: [String: Any]])
    }

    /// A hand-written translation can silently drop or reorder a format argument, and the crash or
    /// the wrong value only shows up in Turkish. Conversion types are compared rather than the raw
    /// specifiers, because Turkish word order often needs positional forms (`%1$@`) where the
    /// English source has plain `%@`.
    @Test("Turkish translations keep the format arguments and line structure of their source")
    func turkishTranslationsPreserveStructure() throws {
        let strings = try Self.catalogStrings()
        let specifier = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ll|l|h)?([@dfsu])")

        func conversions(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return specifier.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }.sorted()
        }

        var mismatches: [String] = []
        for (key, entry) in strings {
            guard (entry["extractionState"] as? String) != "stale" else { continue }
            let unit = (entry["localizations"] as? [String: Any])?["tr"] as? [String: Any]
            guard let stringUnit = unit?["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String else { continue }
            let source = ((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])
                .flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String } ?? key
            /// A plural variation stands in for its argument as `%#@name@` and expands to a real
            /// specifier per case, so its token set never matches a translation that spells the
            /// argument out. Those entries are covered by the catalog's own variation rules.
            guard !source.contains("%#@"), !value.contains("%#@") else { continue }
            guard conversions(source) != conversions(value)
                || source.filter(\.isNewline).count != value.filter(\.isNewline).count else { continue }
            mismatches.append(key)
        }

        #expect(mismatches.isEmpty, "Turkish drops or adds arguments:\n\(mismatches.sorted().joined(separator: "\n"))")
    }

    @Test("No Turkish entry claims to be translated while still holding its English text")
    func turkishTranslationsAreNotEnglish() throws {
        let strings = try Self.catalogStrings()

        var untranslated: [String] = []
        for (key, entry) in strings {
            guard (entry["extractionState"] as? String) != "stale" else { continue }
            /// Single words are skipped: many are genuinely identical across the two languages, and
            /// the false claims this exists to catch were phrases and whole sentences.
            guard key.contains(" "), !Self.identicalByDesign.contains(key) else { continue }
            let unit = (entry["localizations"] as? [String: Any])?["tr"] as? [String: Any]
            guard let stringUnit = unit?["stringUnit"] as? [String: Any],
                  (stringUnit["state"] as? String) == "translated",
                  (stringUnit["value"] as? String) == key else { continue }
            untranslated.append(key)
        }

        #expect(
            untranslated.isEmpty,
            "Marked translated but still English:\n\(untranslated.sorted().joined(separator: "\n"))"
        )
    }
}
