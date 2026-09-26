import Foundation

/// The document an edit replaces the stored one with, in the order the user wrote it.
///
/// A whole-document replace is the only write that keeps the written order: `$set` adds new fields
/// in lexicographic order and reads a dotted name as a path. The stored `_id` goes first and cannot
/// change, and one the user left out is put back rather than read as a request to drop it.
struct MongoDocumentReplacement: Equatable, Sendable {
    let document: MongoDocumentText
    let changesDocument: Bool

    /// Both documents as canonical Extended JSON.
    init(original: MongoDocumentText, edited: MongoDocumentText) throws {
        let field = MongoDocumentIdentity.field
        guard let identity = original.value(of: field) else { throw MongoDBDocumentEditingError.missingIdentity }
        if let editedIdentity = edited.value(of: field),
           !editedIdentity.compactText.utf8.elementsEqual(identity.compactText.utf8) {
            throw MongoDBDocumentEditingError.identityChanged
        }
        let fields = edited.members.filter { !$0.key.utf8.elementsEqual(field.utf8) }
        if let stamped = fields.first(where: { Self.isEmptyTimestamp($0.value) }) {
            throw MongoDBDocumentEditingError.emptyTimestamp(stamped.key)
        }
        document = MongoDocumentText(members: [MongoDocumentText.Member(key: field, value: identity)] + fields)
        changesDocument = !document.compactText.utf8.elementsEqual(original.compactText.utf8)
    }

    /// `Timestamp(0, 0)` in a top-level field, which the server replaces with the current time
    /// whenever it writes the document, so saving it would change a value nobody edited.
    static func isEmptyTimestamp(_ value: MongoDocumentText.Value) -> Bool {
        value.compactText == #"{"$timestamp":{"t":0,"i":0}}"#
    }

    static func emptyTimestampField(in document: MongoDocumentText) -> String? {
        document.members.first { isEmptyTimestamp($0.value) }?.key
    }
}
