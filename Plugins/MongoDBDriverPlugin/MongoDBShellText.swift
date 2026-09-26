import Foundation
import TableProPluginKit

/// The comment, the collection expression and the member name the plugin writes around a name the
/// server chose, each escaped for where it stands.
///
/// A name reaches these statements from the server, and a person then runs them from an editor
/// tab. A view named with a line feed in it ended its own `// View:` comment, and the text after
/// the line feed ran as a statement of its own.
enum MongoDBShellText {
    /// A line comment that ends where the line does. Every character that ends a line for
    /// JavaScript or for the editor's statement scanner, and every other control character, is
    /// written as its escape.
    static func comment(_ text: String) -> String {
        var line = "// "
        for scalar in text.unicodeScalars {
            if let escape = MongoScriptJson.lineBreakingEscape(scalar) {
                line.append(escape)
            } else {
                line.unicodeScalars.append(scalar)
            }
        }
        return line
    }

    /// `db.<name>` for a name made only of identifier characters, and `db.getCollection("<name>")`
    /// for any other.
    ///
    /// The test runs one scalar at a time. `Character.isLetter` reads a grapheme's first scalar
    /// only, so a test by `Character` passes punctuation that shares a grapheme with a letter.
    static func collection(_ name: String) -> String {
        guard isIdentifier(name), !MongoCollectionAccessor.isShadowedByDatabaseMember(name) else {
            return namedCollection(name)
        }
        return "db.\(name)"
    }

    /// `db.getCollection("<name>")`, which reaches every name.
    static func namedCollection(_ name: String) -> String {
        "db.getCollection(\(MongoScriptJson.jsonString(name)))"
    }

    /// A member name as an object literal key. Written as a plain key, `__proto__` sets the
    /// object's prototype and adds no member, so the field never reached the server. A computed
    /// key adds it like any other name, in TablePro's shell and in mongosh.
    static func memberName(_ name: String) -> String {
        let literal = MongoScriptJson.jsonString(name)
        return name == "__proto__" ? "[\(literal)]" : literal
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || first.properties.isXIDStart else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || $0.properties.isXIDContinue }
    }
}
