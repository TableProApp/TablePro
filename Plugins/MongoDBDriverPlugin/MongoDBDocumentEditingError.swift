import Foundation

/// Why a document cannot be opened for editing or saved, in words for the user.
enum MongoDBDocumentEditingError: Error, Equatable, LocalizedError {
    case unsupportedOperation
    case unknownDocument
    case documentChanged
    case ambiguousIdentity
    case identityChanged
    case missingIdentity
    case inexactAsText
    case emptyTimestamp(String)
    case tooLarge
    case serverTooOld
    case view
    case timeSeries
    case notACollection(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            return String(localized: "MongoDB cannot make this change to a document.")
        case .unknownDocument:
            return String(localized: "This row does not name a stored document.")
        case .documentChanged:
            return String(
                localized: "The document changed on the server after it was opened, so nothing was saved. Copy your text, then open it again."
            )
        case .ambiguousIdentity:
            return String(localized: "More than one document has this _id, so it cannot be edited here.")
        case .identityChanged:
            return String(
                localized: "The _id cannot change. Put the original _id back, or insert a new document instead."
            )
        case .missingIdentity:
            return String(localized: "This document has no _id, so it cannot be edited here.")
        case .inexactAsText:
            return String(
                localized: "This document holds a value text cannot write back exactly, such as a subdocument like {\"$numberInt\": \"5\"}."
            )
        case .emptyTimestamp(let field):
            return String(
                format: String(
                    localized: "The top-level field \u{201C}%@\u{201D} holds Timestamp(0, 0), which MongoDB replaces with the current time on every save."
                ),
                field
            )
        case .tooLarge:
            return String(
                localized: "This document is too large to edit here. Saving it would send more than 16 MB to the server."
            )
        case .serverTooOld:
            return String(localized: "Editing a document needs MongoDB 4.0 or later.")
        case .view:
            return String(localized: "This is a view, so its documents cannot be edited. Edit them in the collection the view reads.")
        case .timeSeries:
            return String(
                localized: "This is a time-series collection, which cannot replace a single document, so its documents cannot be edited here."
            )
        case .notACollection(let type):
            return String(
                format: String(localized: "MongoDB lists this as a \u{201C}%@\u{201D} rather than a collection, so its documents cannot be edited here."),
                type
            )
        }
    }
}
