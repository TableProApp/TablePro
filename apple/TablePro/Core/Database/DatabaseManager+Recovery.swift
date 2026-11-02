import Foundation

extension DatabaseManager {
    // Contract for the surfaces lane; the recovery lane replaces this with the real loop handle.
    internal func cancelRecovery(for connectionId: UUID) {}
}
