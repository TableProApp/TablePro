import Foundation

public enum SQLCompletionTriggerPolicy {
    // A clause with a full column list behind it stays shut until the user types or asks; the listed ones answer with
    // a short, closed list. An opening quote counts as typed input: it sits in `prefixRange` but not in `prefix`.
    public static func suppressesEmptyPrefix(_ context: SQLContext, isManualTrigger: Bool) -> Bool {
        guard !isManualTrigger,
              context.prefix.isEmpty,
              context.prefixRange.isEmpty,
              context.dotPrefix == nil else { return false }

        switch context.clauseType {
        case .from, .join, .into, .set, .insertColumns, .on,
             .alterTableColumn, .returning, .using, .dropObject, .createIndex, .castTarget:
            return false
        case .select where !context.isAfterComma:
            return false
        default:
            return true
        }
    }

    public static func suppressesAfterStatementBreak(in text: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset - 1 < text.length else { return false }

        let previous = text.character(at: offset - 1)
        let semicolon = UInt16(UnicodeScalar(";").value)
        let newline = UInt16(UnicodeScalar("\n").value)
        guard previous == semicolon || previous == newline else { return false }
        guard offset < text.length else { return true }

        return text.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
