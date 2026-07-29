import Foundation

struct PrincipalApplyError: LocalizedError {
    let failedStatement: SchemaStatement
    let appliedCount: Int
    let totalCount: Int
    let rolledBack: Bool
    let underlying: Error

    var errorDescription: String? {
        underlying.localizedDescription
    }

    var partialApplicationMessage: String? {
        guard !rolledBack, appliedCount > 0 else { return nil }
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
    }
}
