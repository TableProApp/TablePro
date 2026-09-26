//
//  MongoDBWriteRefusal.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// A grid change the shell statement cannot carry as the value the user sees.
///
/// Each one used to be left out of the statement, or written as something else, while the save
/// reported success. The generator throws it instead, and it reaches the user as the reason the
/// save was refused.
enum MongoDBWriteRefusal: Error, Equatable {
    case binarySubtypeUnknown(field: String)
    case binaryNeedsBytes(field: String)
    case truncatedValue(field: String)
    case unwritableFieldName(field: String)
    case fieldNeedsMongoDB5(field: String)
    case unreadableJSON(field: String)
    case integerTooLarge(field: String)
    case reorderedByTheShell(field: String)
    case noDefaultValue(field: String)
    case identityChanged
    case missingIdentity

    var reason: String {
        switch self {
        case .binarySubtypeUnknown(let field):
            return String(
                format: String(localized: "The binary subtype of %@ is not known, so saving could store a different kind of binary. Change this field with a query."),
                field
            )
        case .binaryNeedsBytes(let field):
            return String(
                format: String(localized: "%@ holds binary data. Edit it as bytes, or set it to NULL."),
                field
            )
        case .truncatedValue(let field):
            return String(
                format: String(localized: "The value in %@ is shortened for display, so saving it would store only the part shown. Change this field with a query."),
                field
            )
        case .unwritableFieldName(let field):
            return String(
                format: String(localized: "The shell cannot write a field named \u{201C}%@\u{201D} into a new document. Insert this document with a query."),
                field
            )
        case .fieldNeedsMongoDB5(let field):
            return String(
                format: String(localized: "A field named \u{201C}%@\u{201D} can only be changed on MongoDB 5.0 or later, which can address a dot or a leading $ in a name."),
                field
            )
        case .unreadableJSON(let field):
            return String(
                format: String(localized: "%@ holds a document or an array, and this text is not valid JSON."),
                field
            )
        case .integerTooLarge(let field):
            return String(
                format: String(localized: "A number in %@ is larger than a 64-bit integer. Write it as a decimal, such as {\"$numberDecimal\": \"12345678901234567890\"}."),
                field
            )
        case .reorderedByTheShell(let field):
            return String(
                format: String(localized: "The shell would reorder or drop a key inside %@: it lists number-like keys first and drops __proto__. Change this field with a query."),
                field
            )
        case .noDefaultValue(let field):
            return String(
                format: String(localized: "MongoDB has no default values, so %@ cannot be set to DEFAULT."),
                field
            )
        case .identityChanged:
            return String(localized: "MongoDB does not let a document's _id change. Duplicate the row with the new _id, then delete this one.")
        case .missingIdentity:
            return String(localized: "This row has no _id, so TablePro cannot tell which document to change.")
        }
    }

    func refusal(ofRow rowIndex: Int) -> PluginRowWriteRefusal {
        PluginRowWriteRefusal(rowIndex: rowIndex, reason: reason)
    }
}
