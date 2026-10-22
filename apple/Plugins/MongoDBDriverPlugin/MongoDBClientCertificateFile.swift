import Foundation
import TableProPluginKit

// libmongoc reads the certificate chain and then the private key from the one tlsCertificateKeyFile.
nonisolated struct MongoDBClientCertificateFile: Sendable {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TableProMongoDBClientCertificates", isDirectory: true)

    let path: String

    static func joining(_ ssl: SSLConfiguration) throws -> MongoDBClientCertificateFile? {
        guard ssl.isEnabled,
              !ssl.clientCertificatePath.isEmpty,
              !ssl.clientKeyPath.isEmpty,
              ssl.clientKeyPath != ssl.clientCertificatePath else {
            return nil
        }
        return try write(certificatePath: ssl.clientCertificatePath, keyPath: ssl.clientKeyPath)
    }

    static func combinedPEM(certificate: String, key: String) -> String {
        certificate.last?.isNewline == true ? certificate + key : certificate + "\n" + key
    }

    static func write(certificatePath: String, keyPath: String) throws -> MongoDBClientCertificateFile {
        guard let certificate = try? String(contentsOfFile: certificatePath, encoding: .utf8) else {
            throw MongoDBError(
                code: 0,
                message: String(format: String(localized: "The client certificate at %@ could not be read."), certificatePath)
            )
        }
        guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw MongoDBError(
                code: 0,
                message: String(format: String(localized: "The client key at %@ could not be read."), keyPath)
            )
        }

        let fileManager = FileManager.default
        let path = directory.appendingPathComponent("\(UUID().uuidString).pem").path
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw writeFailure
        }
        guard fileManager.createFile(
            atPath: path,
            contents: Data(combinedPEM(certificate: certificate, key: key).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw writeFailure
        }
        return MongoDBClientCertificateFile(path: path)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static var writeFailure: MongoDBError {
        MongoDBError(
            code: 0,
            message: String(localized: "The client certificate and key could not be written to a temporary file.")
        )
    }
}
