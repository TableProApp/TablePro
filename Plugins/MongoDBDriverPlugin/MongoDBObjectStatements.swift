import Foundation

/// The statements Drop, Truncate and Edit View Definition write for one collection or view, each
/// naming it as a string literal the plugin's own escaper wrote.
///
/// Each used to escape the name by hand. The view template escaped the quote alone, so a
/// backslash just before a quote ended the string and the rest of the name ran as statements. The
/// others escaped one `Character` at a time, which reads a carriage return and line feed as a
/// single line feed, so Drop on `a\r\nb` dropped `a\nb`.
enum MongoDBObjectStatements {
    static func drop(_ name: String) -> String {
        "\(MongoDBShellText.namedCollection(name)).drop()"
    }

    /// `deleteMany({})` empties the collection and leaves it, its indexes and its options in place,
    /// which is what Truncate means. `drop()` would take all three.
    static func truncate(_ name: String) -> String {
        "\(MongoDBShellText.namedCollection(name)).deleteMany({})"
    }

    /// What Edit View Definition opens when the view's own definition could not be read.
    static func redefineViewTemplate(_ name: String) -> String {
        let command = MongoDBJsonLayout.shellObject([
            (key: "collMod", value: MongoScriptJson.jsonString(name)),
            (key: "viewOn", value: MongoScriptJson.jsonString("source_collection")),
            (key: "pipeline", value: "[ { \"$match\" : { } } ]")
        ])
        return "db.runCommand(\(command))"
    }
}
