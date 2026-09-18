//
//  RemoteApplyOutcome.swift
//  TablePro
//

import Foundation

/// What applying one record from another device did.
///
/// A `Bool` cannot carry this. A store that refused every write and a pull that carried nothing new
/// both answered false, so the coordinator read a broken store as a quiet sync and committed the
/// server token over records it had never stored. They are three answers, and only one of them
/// means the batch has to arrive again.
internal enum RemoteApplyOutcome: Equatable {
    /// The record was written.
    case applied
    /// Nothing to do: a tombstone, or a record identical to the one already stored.
    case skipped
    /// The record could not be persisted, so it is not in the local store and has to be re-fetched.
    case failed
}
