import Foundation

/// Which stored document a grid row is: the compact canonical Extended JSON of its `_id`.
///
/// The grid shows an `_id` as display text, and display text cannot say which BSON value it came
/// from: an ObjectId and a string with the same hex read the same, and so do `1` and
/// `NumberLong(1)`. So the locator is taken from the document itself when the driver reads it, and
/// the document is found again by comparing that text byte for byte, never by what a query matches.
/// A query is lenient: `{_id: 1}` finds a stored double `1`, and a collection's collation finds
/// `"ABC"` for `"abc"`.
struct MongoDocumentIdentity: Equatable, Sendable {
    static let field = "_id"

    let locator: String

    /// The locator of a document read as canonical Extended JSON, or nil when it has no `_id`.
    static func locator(inDocument json: String) -> String? {
        MongoDocumentText.topLevelValue(named: field, in: json)?.compactText
    }

    /// Reads a locator strictly, as one value and nothing else, since it comes back from outside
    /// the driver and becomes part of a query.
    init(locator text: String) throws {
        guard let document = try? MongoDocumentText(parsing: #"{"\#(Self.field)":\#(text)}"#),
              document.members.count == 1,
              let member = document.members.first,
              member.key == Self.field,
              !MongoExtendedJsonType.isQueryOperator(member.value) else {
            throw MongoDBDocumentEditingError.unknownDocument
        }
        locator = member.value.compactText
    }

    var filter: String {
        #"{"\#(Self.field)":\#(locator)}"#
    }

    /// Whether a stored document, as canonical Extended JSON, is the one this names. Compared as
    /// bytes, because Swift's string equality treats two Unicode spellings of one character as
    /// equal and the server does not.
    func identifies(_ storedJson: String) -> Bool {
        guard let stored = Self.locator(inDocument: storedJson) else { return false }
        return stored.utf8.elementsEqual(locator.utf8)
    }
}
