//
//  SchemaLoadPolicy.swift
//  TablePro
//

import Foundation

enum SchemaLoadFailureDisposition: Equatable {
    case ignore
    case awaitConnection
    case surface(String)
}

/// What a failed object-list load must do next.
///
/// A load that failed while the connection still had its driver is a metadata failure the user can act
/// on, so it ends in the sidebar's error state and its Retry button. One that lost its driver mid-flight
/// is the launch race the post-connect subscription was written for, and waiting is the only exit that
/// does not re-enter the load that just failed. A cancelled load belongs to a window that is going away
/// and must do neither.
///
/// `hasLiveDriver` is the predicate, not "a session exists": a session is registered with a `.connecting`
/// status before its driver connects, so its browse scope is already non-nil while the connection is
/// still being made. Reporting that as a failure marks a connection that is merely slow as permanently
/// failed, with nothing left to retry it.
enum SchemaLoadPolicy {
    static func disposition(for error: Error, hasLiveDriver: Bool) -> SchemaLoadFailureDisposition {
        if error is CancellationError { return .ignore }
        guard hasLiveDriver else { return .awaitConnection }
        return .surface(error.localizedDescription)
    }
}
