//
//  QueryPlanHistoryLocalizationTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Query plan history localization")
struct QueryPlanHistoryLocalizationTests {
    private static let requiredKeys = [
        "%+.3f ms",
        "%.3f ms",
        "A structured comparison is unavailable because one plan could not be parsed. Showing raw output.",
        "Actual Loops",
        "Actual Rows",
        "Actual Startup Time",
        "Actual Total Time",
        "Added",
        "Baseline",
        "Change",
        "Changed",
        "Close",
        "Compare this plan with an earlier run",
        "Cost",
        "Current",
        "Earlier Runs",
        "Estimated Rows",
        "Estimated Startup Cost",
        "Estimated Total Cost",
        "Estimated Width",
        "Estimated rows",
        "Execution time",
        "History",
        "Loading plan history…",
        "Metric",
        "Modified",
        "No Earlier Plans",
        "No node changes.",
        "No raw plan output.",
        "Node Changes",
        "Node count",
        "Output truncated for display",
        "Plan History",
        "Plan History Unavailable",
        "Planning time",
        "Removed",
        "Run this EXPLAIN again to create a comparison baseline.",
        "The query history store could not be opened."
    ]

    private static let supportedLocales = ["ko", "tr", "vi", "zh-Hans", "zh-Hant"]

    @Test("Every plan history string is translated in each supported locale")
    func catalogCoversPlanHistoryUI() throws {
        let strings = try Self.catalogStrings()
        var missing: [String] = []

        for key in Self.requiredKeys {
            guard let entry = strings[key],
                  let localizations = entry["localizations"] as? [String: Any]
            else {
                missing.append("catalog: \(key)")
                continue
            }

            for locale in Self.supportedLocales {
                let localization = localizations[locale] as? [String: Any]
                let stringUnit = localization?["stringUnit"] as? [String: Any]
                let state = stringUnit?["state"] as? String
                let value = stringUnit?["value"] as? String
                if state != "translated" || value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    missing.append("\(locale): \(key)")
                }
            }
        }

        #expect(missing.isEmpty, "Missing plan history translations:\n\(missing.joined(separator: "\n"))")
    }

    @Test("Localized plan durations preserve their format argument")
    func durationFormatsPreserveArguments() throws {
        let strings = try Self.catalogStrings()
        let formats = ["%+.3f ms": "%+.3f", "%.3f ms": "%.3f"]

        for (key, formatArgument) in formats {
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])

            for locale in Self.supportedLocales {
                let localization = try #require(localizations[locale] as? [String: Any])
                let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(value.contains(formatArgument), "\(locale) changed format argument for \(key)")
            }
        }
    }

    private static func catalogStrings() throws -> [String: [String: Any]] {
        let url = try repositoryRoot()
            .appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let catalog = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try #require(catalog["strings"] as? [String: [String: Any]])
    }

    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CatalogError.repositoryRootNotFound
    }

    private enum CatalogError: Error {
        case repositoryRootNotFound
    }
}
