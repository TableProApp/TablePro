import Foundation
import TableProModels

nonisolated extension Cell {
    // A long key is cut for display, but its ref carries the whole key the driver read. A binary key's bytes are not
    // text, so it gives none.
    func keyText(column: String) -> String? {
        switch self {
        case .text(let value):
            value
        case .truncatedText(_, _, let ref?):
            ref.primaryKey.first { $0.column == column }?.value
        case .truncatedText, .binary, .null:
            nil
        }
    }
}
