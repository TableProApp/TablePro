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

    /// What a connection's content appearing asks of its schema.
    ///
    /// Appearance is not a connect: switching connection in a window takes a pane out of the window
    /// and puts it back, which runs every `onAppear` again. Only a catalog or an autocomplete
    /// provider that is not there yet is work; one that is loaded stays as it is, and a failed one
    /// waits for the sidebar's Retry rather than being retried by a click on another connection.
    static func activationAction(
        hasLiveDriver: Bool,
        catalog: SchemaState,
        autocompletePopulated: Bool,
        loadInFlight: Bool
    ) -> SchemaActivationAction {
        guard !loadInFlight else { return .none }
        guard hasLiveDriver else { return .awaitConnection }
        switch catalog {
        case .idle:
            return .load
        case .loading, .failed:
            return .none
        case .loaded:
            return autocompletePopulated ? .none : .load
        }
    }
}

extension SchemaLoadPolicy {
    /// Whether a schema load already running answers a connect, so the connect's own refresh can
    /// wait for it instead of fetching everything a second time. Only a load reading through the
    /// driver that just connected does: one started on the driver a reconnect replaced can finish
    /// with that driver's catalog still loaded.
    static func inFlightLoadCoversConnect(
        loadDriver: (any DatabaseDriver)?,
        connectedDriver: (any DatabaseDriver)?
    ) -> Bool {
        guard let loadDriver, let connectedDriver else { return false }
        return loadDriver === connectedDriver
    }
}

enum SchemaActivationAction: Equatable {
    case none
    case awaitConnection
    case load
}
