//
//  LibPQCheckConstraintCoverageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct LibPQCheckConstraintCoverageTests {
    private static let pluginDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
    }()

    private static let sharedExtensionOwner = "LibPQBackedDriver"

    private static func pluginSources() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(at: pluginDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private static func matches(_ pattern: String, in text: String) throws -> [NSTextCheckingResult] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]).matches(in: text, range: range)
    }

    private static func firstCapture(of match: NSTextCheckingResult, in text: String) -> String {
        (text as NSString).substring(with: match.range(at: 1))
    }

    private static func driverClassesByTypeId(pluginSource: String) throws -> [String: String] {
        var classes: [String: String] = [:]
        for match in try matches(#"case "([^"]+)": return (\w+)\(config: config\)"#, in: pluginSource) {
            classes[firstCapture(of: match, in: pluginSource)] = (pluginSource as NSString).substring(with: match.range(at: 2))
        }
        for match in try matches(#"default: return (\w+)\(config: config\)"#, in: pluginSource) {
            classes["PostgreSQL"] = firstCapture(of: match, in: pluginSource)
        }
        return classes
    }

    private static func owners(ofMember member: String, in sources: [String]) throws -> Set<String> {
        var owners: Set<String> = []
        for source in sources {
            let declarations = try matches(#"^(?:final )?(?:class|extension) (\w+)"#, in: source)
            for memberMatch in try matches(#"^    func \#(member)\("#, in: source) {
                guard let owner = declarations.last(where: { $0.range.location < memberMatch.range.location }) else {
                    continue
                }
                owners.insert(firstCapture(of: owner, in: source))
            }
        }
        return owners
    }

    private static func superclass(of className: String, in sources: [String]) throws -> String? {
        for source in sources {
            if let match = try matches(#"^(?:final )?class \#(className): (\w+)"#, in: source).first {
                return firstCapture(of: match, in: source)
            }
        }
        return nil
    }

    private static func lineage(of className: String, in sources: [String]) throws -> [String] {
        var chain = [className]
        while let parent = try superclass(of: chain[chain.count - 1], in: sources), parent != sharedExtensionOwner {
            chain.append(parent)
        }
        return chain
    }

    @Test("Every libpq driver whose type offers check constraints can fetch them")
    func everyCheckConstraintTypeHasAFetch() throws {
        let sources = try Self.pluginSources()
        let pluginSource = try String(
            contentsOf: Self.pluginDirectory.appendingPathComponent("PostgreSQLPlugin.swift"),
            encoding: .utf8
        )
        let drivers = try Self.driverClassesByTypeId(pluginSource: pluginSource)
        #expect(Set(drivers.keys) == ["PostgreSQL", "Redshift", "CockroachDB", "PGlite"])

        let owners = try Self.owners(ofMember: "fetchCheckConstraints", in: sources)
        #expect(!owners.isEmpty)
        for (typeId, className) in drivers where DatabaseType(rawValue: typeId).supportsCheckConstraints {
            let lineage = try Self.lineage(of: className, in: sources)
            let reachesAFetch = owners.contains(Self.sharedExtensionOwner) || !owners.isDisjoint(with: lineage)
            #expect(reachesAFetch, "\(typeId) offers check constraints but \(className) has no fetchCheckConstraints")
        }
    }

    @Test("No type offers check constraint editing without schema editing")
    func checkConstraintEditingNeedsSchemaEditing() {
        let inconsistent = DatabaseType.allKnownTypes.filter {
            $0.supportsCheckConstraintEditing && !$0.supportsSchemaEditing
        }
        #expect(inconsistent.isEmpty, "Check constraint editing on a read-only structure: \(inconsistent.map(\.rawValue))")
    }
}
