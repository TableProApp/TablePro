import Foundation

/// One entry `listCollections` returned: what the namespace is, and the options it was created with.
///
/// libmongoc's name listing keeps each entry's `name` and drops its `type`, so every view reached
/// the app as a collection and was offered edits, Rename and Truncate that the server refuses with
/// CommandNotSupportedOnView.
struct MongoDBNamespaceEntry {
    static let systemPrefix = "system."

    let name: String
    let serverType: String
    let optionsJson: String?

    init?(json: String) {
        let members = MongoScriptJson.members(of: json)
        guard let nameJson = members.first(where: { $0.key == "name" })?.value,
              let name = MongoScriptJson.decodedString(nameJson) else {
            return nil
        }
        self.name = name
        serverType = members.first { $0.key == "type" }
            .flatMap { MongoScriptJson.decodedString($0.value) } ?? "collection"
        optionsJson = members.first { $0.key == "options" }?.value
    }

    var isView: Bool { serverType == "view" }

    var isSystem: Bool { name.hasPrefix(Self.systemPrefix) }

    /// A time-series collection stays a table: it takes finds, inserts and deletes like one, and
    /// refuses only in-place updates and a rename, both of which the server reports itself.
    var pluginTableType: String {
        if isView { return "VIEW" }
        if isSystem { return "SYSTEM TABLE" }
        return "TABLE"
    }

    func option(_ key: String) -> String? {
        guard let optionsJson else { return nil }
        return MongoScriptJson.member(of: optionsJson, key: key)
    }

    func numberOption(_ key: String) -> Int64? {
        guard let optionsJson else { return nil }
        return MongoScriptJson.number(in: optionsJson, key: key)
    }

    /// The statement that creates this view again, collation included.
    func createViewStatement() -> String? {
        guard let source = viewSource else { return nil }
        var arguments = [
            MongoScriptJson.jsonString(name),
            MongoScriptJson.jsonString(source),
            MongoDBJsonLayout.indented(pipelineLiteral)
        ]
        if let collation = option("collation") {
            let options = MongoDBJsonLayout.shellObject([
                (key: "collation", value: MongoDBShellLiteral.render(MongoDBCollation.portable(collation)))
            ])
            arguments.append(MongoDBJsonLayout.indented(options))
        }
        return "db.createView(\(arguments.joined(separator: ", ")))"
    }

    /// The statement that redefines this view in place. `collMod` keeps the view's collation and
    /// refuses to be given one, and `createView` on a name that exists fails with NamespaceExists.
    func collModStatement() -> String? {
        guard let source = viewSource else { return nil }
        let command = MongoDBJsonLayout.shellObject([
            (key: "collMod", value: MongoScriptJson.jsonString(name)),
            (key: "viewOn", value: MongoScriptJson.jsonString(source)),
            (key: "pipeline", value: pipelineLiteral)
        ])
        return "db.runCommand(\(MongoDBJsonLayout.indented(command)))"
    }

    private var pipelineLiteral: String {
        MongoDBShellLiteral.render(option("pipeline") ?? "[]")
    }

    private var viewSource: String? {
        guard isView else { return nil }
        return option("viewOn").flatMap(MongoScriptJson.decodedString)
    }
}

/// The shell text Show DDL, Copy DDL and the Structure tab's DDL show for one namespace.
///
/// A view's header reads `// View:` so MQL export, which appends whatever follows a
/// `// Collection:` line after a collection's documents, never writes a `createView` after the
/// documents it exported from that view.
enum MongoDBNamespaceDDL {
    static func text(name: String, entry: MongoDBNamespaceEntry?, indexes: [MongoDBIndexEntry]) -> String {
        if let entry, entry.isView {
            return [MongoDBShellText.comment("View: \(name)"), entry.createViewStatement()]
                .compactMap { $0 }
                .joined(separator: "\n")
        }

        var sections = [MongoDBShellText.comment("Collection: \(name)")]
        if let entry {
            sections += optionSections(of: entry)
        }
        let statements = indexes.filter { !$0.isPrimary }.map { $0.createIndexStatement(collection: name) }
        if !statements.isEmpty {
            sections.append("\n" + MongoDBShellText.comment("Indexes"))
            sections += statements
        }
        return sections.joined(separator: "\n")
    }

    private static func optionSections(of entry: MongoDBNamespaceEntry) -> [String] {
        var sections: [String] = []
        if entry.option("capped") == "true" {
            var line = "Capped: true, size: \(entry.numberOption("size") ?? 0)"
            if let max = entry.numberOption("max") { line += ", max: \(max)" }
            sections.append(MongoDBShellText.comment(line))
        }
        if let timeSeries = entry.option("timeseries") {
            sections.append(MongoDBShellText.comment("Time series: \(MongoDBShellLiteral.render(timeSeries))"))
        }
        if let validator = entry.option("validator") {
            let command = MongoDBJsonLayout.shellObject([
                (key: "collMod", value: MongoScriptJson.jsonString(entry.name)),
                (key: "validator", value: MongoDBShellLiteral.render(validator))
            ])
            let statement = "db.runCommand(\(MongoDBJsonLayout.indented(command)))"
            sections.append("\n" + MongoDBShellText.comment("Validator") + "\n" + statement)
        }
        return sections
    }
}
