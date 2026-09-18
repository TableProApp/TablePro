import Foundation
@testable import TableProMobile

final class InMemoryCertificateStore: CertificateMaterialStoring, @unchecked Sendable {
    enum StoreError: Error { case refused }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    var refusesStores = false

    private func key(_ role: CertificateRole, _ id: UUID) -> String {
        "\(id.uuidString).\(role.rawValue)"
    }

    func store(_ pem: String, role: CertificateRole, for connectionId: UUID) throws {
        guard !refusesStores else { throw StoreError.refused }
        lock.withLock { values[key(role, connectionId)] = pem }
    }

    func pem(role: CertificateRole, for connectionId: UUID) -> String? {
        lock.withLock { values[key(role, connectionId)] }
    }

    func delete(role: CertificateRole, for connectionId: UUID) {
        _ = lock.withLock { values.removeValue(forKey: key(role, connectionId)) }
    }

    func deleteAll(for connectionId: UUID) {
        for role in CertificateRole.allCases {
            delete(role: role, for: connectionId)
        }
    }
}
