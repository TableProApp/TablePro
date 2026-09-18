import Foundation

struct PrincipalApplyError: LocalizedError {
    /// What became of the statements that ran before the failure.
    enum Disposition: Equatable {
        /// The app rolled its own transaction back, so nothing stands.
        case rolledBack
        /// Applied as they ran, on a connection that does not roll principal statements back.
        case applied
        /// Pending inside a transaction the session already held, which the app must not end.
        case pendingInSessionTransaction
    }

    let failedStatement: SchemaStatement
    let appliedCount: Int
    let totalCount: Int
    let disposition: Disposition
    let underlying: Error

    var errorDescription: String? {
        underlying.localizedDescription
    }

    var partialApplicationMessage: String? {
        guard appliedCount > 0 else { return nil }
        switch disposition {
        case .rolledBack:
            return nil
        case .applied:
            return String(
                format: String(
                    localized: """
                        %1$lld of %2$lld statements were applied. \
                        This connection does not roll back user and role changes.
                        """
                ),
                appliedCount,
                totalCount
            )
        case .pendingInSessionTransaction:
            return String(
                format: String(
                    localized: """
                        %1$lld of %2$lld statements ran inside the transaction already open on this \
                        connection. Commit it to keep them, or roll it back to discard them.
                        """
                ),
                appliedCount,
                totalCount
            )
        }
    }
}
