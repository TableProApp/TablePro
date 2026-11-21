//
//  PluginMetadataCuratedParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Until a plugin's code loads, the app answers from the type's curated entry; registration then replaces the entry with
// what the plugin declares, so a field the two disagree on changes the app at the first connect of a launch. Every
// driver plugin built beside the test host is compared: the bundled ones on every run, the registry ones once AllPlugins
// built them, which CI's macOS Tests job does before the Unit plan.
struct PluginMetadataCuratedParityTests {
    @Test("Each built driver plugin registers exactly the entry the app curates for its type")
    func pluginsRegisterTheirCuratedEntries() throws {
        let curated = Dictionary(
            PluginMetadataRegistry.shared.builtInDefaults().map { ($0.typeId, $0.snapshot) },
            uniquingKeysWith: { first, _ in first }
        )
        var compared: [String] = []
        for url in BuiltPlugins.bundleURLs() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let bundle = Bundle(url: url) else {
                Issue.record("\(name) is not a bundle")
                continue
            }
            do {
                try bundle.loadAndReturnError()
            } catch {
                Issue.record("\(name) does not load: \(error)")
                continue
            }
            guard let driver = bundle.principalClass as? any DriverPlugin.Type else {
                let provides = bundle.object(forInfoDictionaryKey: "TableProProvidesDatabaseTypeIds") as? [String] ?? []
                if !provides.isEmpty {
                    Issue.record("\(name) provides \(provides) but its principal class is no DriverPlugin")
                }
                continue
            }
            let typeId = driver.databaseTypeId
            guard let entry = curated[typeId] else {
                Issue.record("\(name) serves \(typeId), which has no curated entry")
                continue
            }
            compared.append(typeId)
            let built = PluginMetadataRegistry.metadataSnapshot(
                from: driver,
                isDownloadable: driver.isDownloadable,
                existing: entry
            )
            let registered = PluginMetadataRegistry.adoptingCuratedEntry(
                built.withBranding(from: entry),
                registryDefault: entry,
                typeId: typeId
            )
            // A curated explain list is only the fallback for a plugin that declares none, and Oracle and SQL Server keep
            // it empty so a plugin without its own plans offers no Explain.
            let checked = entry.explainVariants.isEmpty ? registered.withExplainVariants([]) : registered
            for difference in SnapshotDifferences.between(curated: entry, registered: checked) {
                Issue.record("\(typeId) \(difference)")
            }
        }
        let bundledDrivers: Set<String> = ["MySQL", "PostgreSQL", "SQLite", "ClickHouse", "Redis"]
        #expect(bundledDrivers.isSubset(of: Set(compared)), "Compared only \(compared)")
    }
}

private enum BuiltPlugins {
    // The products folder holds every plugin the last build made. A bundled one loads from the app's own PlugIns, as
    // BundledPlugin loads it, so its classes are never loaded from two images.
    static func bundleURLs() -> [URL] {
        let embedded = Bundle.main.builtInPlugInsURL
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        var byName: [String: URL] = [:]
        for folder in [products, embedded].compactMap({ $0 }) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) ?? []
            for url in contents where url.pathExtension == "tableplugin" {
                byName[url.deletingPathExtension().lastPathComponent] = url
            }
        }
        return byName.keys.sorted().compactMap { byName[$0] }
    }
}

// Each stored field, by its path, whose value reads differently in the two snapshots.
private enum SnapshotDifferences {
    static func between(curated: Any, registered: Any) -> [String] {
        differences(curated, registered, path: "")
    }

    private static func differences(_ curated: Any, _ registered: Any, path: String) -> [String] {
        let left = Mirror(reflecting: curated)
        let right = Mirror(reflecting: registered)
        if left.displayStyle == .struct, right.displayStyle == .struct, left.children.count == right.children.count {
            return zip(left.children, right.children).flatMap { pair in
                differences(pair.0.value, pair.1.value, path: joined(path, pair.0.label ?? "?"))
            }
        }
        if left.displayStyle == .optional, right.displayStyle == .optional,
           let wrappedLeft = left.children.first?.value, let wrappedRight = right.children.first?.value {
            return differences(wrappedLeft, wrappedRight, path: path)
        }
        if left.displayStyle == .dictionary, right.displayStyle == .dictionary {
            let curatedEntries = entries(left)
            let registeredEntries = entries(right)
            return Set(curatedEntries.keys).union(registeredEntries.keys).sorted().flatMap { key -> [String] in
                let entryPath = "\(path)[\(key)]"
                switch (curatedEntries[key], registeredEntries[key]) {
                case let (curatedValue?, registeredValue?):
                    return differences(curatedValue, registeredValue, path: entryPath)
                case (nil, _):
                    return ["\(entryPath): only the plugin has it"]
                case (_, nil):
                    return ["\(entryPath): only the curated entry has it"]
                }
            }
        }
        if left.displayStyle == .collection, right.displayStyle == .collection,
           left.children.count == right.children.count {
            return zip(left.children, right.children).enumerated().flatMap { index, pair in
                differences(pair.0.value, pair.1.value, path: "\(path)[\(index)]")
            }
        }
        let curatedText = canonical(curated)
        let registeredText = canonical(registered)
        guard curatedText != registeredText else { return [] }
        if [left.displayStyle, right.displayStyle].allSatisfy({ $0 == .set || $0 == .collection }) {
            let curatedElements = left.children.map { canonical($0.value) }
            let registeredElements = right.children.map { canonical($0.value) }
            let onlyCurated = curatedElements.filter { !registeredElements.contains($0) }.sorted()
            let onlyPlugin = registeredElements.filter { !curatedElements.contains($0) }.sorted()
            return [
                "\(path): only the curated entry has \(clipped(onlyCurated.joined(separator: ", "))); "
                    + "only the plugin has \(clipped(onlyPlugin.joined(separator: ", ")))"
                    + (onlyCurated.isEmpty && onlyPlugin.isEmpty ? " (same elements, another order)" : "")
            ]
        }
        return ["\(path): curated \(clipped(curatedText)), plugin \(clipped(registeredText))"]
    }

    private static func entries(_ mirror: Mirror) -> [String: Any] {
        var result: [String: Any] = [:]
        for child in mirror.children {
            let pair = Array(Mirror(reflecting: child.value).children)
            guard pair.count == 2 else { continue }
            result[canonical(pair[0].value)] = pair[1].value
        }
        return result
    }

    // The same text for equal values: a set's or a dictionary's elements are sorted.
    static func canonical(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        let children = mirror.children.map { child in
            (label: child.label, text: canonical(child.value))
        }
        switch mirror.displayStyle {
        case .set?, .dictionary?:
            return "{" + children.map { $0.text }.sorted().joined(separator: ", ") + "}"
        case .optional?:
            return children.first?.text ?? "nil"
        case .collection?:
            return "[" + children.map { $0.text }.joined(separator: ", ") + "]"
        case .enum?:
            guard let payload = children.first else { return String(describing: value) }
            return "\(payload.label ?? "?")(\(payload.text))"
        case .struct?, .class?, .tuple?:
            guard !children.isEmpty else { return String(describing: value) }
            let fields = children.map { child in child.label.map { "\($0): \(child.text)" } ?? child.text }
            return "\(mirror.subjectType)(" + fields.joined(separator: ", ") + ")"
        default:
            return String(reflecting: value)
        }
    }

    private static func joined(_ path: String, _ label: String) -> String {
        path.isEmpty ? label : "\(path).\(label)"
    }

    private static func clipped(_ text: String) -> String {
        text.count <= 600 ? text : String(text.prefix(600)) + "..."
    }
}
