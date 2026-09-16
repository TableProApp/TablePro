//
//  SQLCompletionTriggerPolicy.swift
//  TablePro
//
//  Which cursor positions open the popup on their own. The query editor and the raw SQL filter
//  field both auto-trigger on every keystroke and both have to answer the same question, so the
//  answer lives here rather than once per surface. The filter field used to decide it from the
//  character before the caret, which cannot see a clause: that shut the PostgreSQL cast list the
//  editor opens and left the two surfaces disagreeing about the same fragment.
//

import Foundation

/// Why a completion request was made, which is what decides whether a position may decline it.
enum SQLCompletionTrigger {
    /// A keystroke. The clause rule decides whether the list is worth opening.
    case automatic
    /// `Ctrl+Space`, or a caller that is not a popup. Every position answers.
    case explicit
}

enum SQLCompletionTriggerPolicy {
    /// A clause with a full column list behind it stays shut until the user types or asks for it.
    /// The clauses listed here answer with a short, closed list instead, so opening one costs the
    /// user nothing. A qualified name is always a closed list too, which is why a dot prefix
    /// exempts the position whatever clause it sits in.
    ///
    /// An opening identifier quote is typed input even though it matches nothing: the analyzer
    /// keeps it inside `prefixRange` so an accepted completion overwrites it, and strips it from
    /// `prefix` so the matcher can work. Reading `prefix` alone reads that as an untouched
    /// position and shuts the list the user just asked for by typing the quote.
    static func suppressesEmptyPrefix(_ context: SQLContext, trigger: SQLCompletionTrigger) -> Bool {
        guard trigger == .automatic,
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
}
