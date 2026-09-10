import Foundation
import TableProModels

extension ConnectionFormViewModel {
    var usesCertificateSection: Bool {
        !isFileBased && type != .oracle && type != .mssql
    }

    var showsCertificateRows: Bool {
        sslMode != .disable
    }

    func loadCertificateSummaries() {
        guard let connectionId = existingConnection?.id else { return }
        for role in CertificateRole.allCases {
            guard let pem = certificateStore.pem(role: role, for: connectionId) else { continue }
            certificateSummaries[role] = summary(for: role, pem: pem)
        }
    }

    func hasCertificate(_ role: CertificateRole) -> Bool {
        certificateSummaries[role] != nil
    }

    func importCertificateFile(_ result: Result<[URL], any Error>, role: CertificateRole) {
        guard let url = pickedURL(from: result) else { return }
        guard let text = readText(at: url) else {
            certificateError = String(localized: "That file is not a PEM certificate. Choose a .pem or .crt file, or paste its contents.")
            return
        }
        adopt(text, role: role)
    }

    func importPastedCertificate(role: CertificateRole) {
        adopt(pastedCertificate, role: role)
        pastedCertificate = ""
    }

    func stagePKCS12(_ result: Result<[URL], any Error>) {
        guard let url = pickedURL(from: result) else { return }
        guard url.startAccessingSecurityScopedResource() else {
            certificateError = String(localized: "TablePro could not read that file.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        pendingPKCS12 = try? Data(contentsOf: url)
        if pendingPKCS12 == nil {
            certificateError = String(localized: "TablePro could not read that file.")
        }
    }

    func importPKCS12() {
        guard let data = pendingPKCS12 else { return }
        defer {
            pendingPKCS12 = nil
            pkcs12Password = ""
        }

        do {
            let material = try PKCS12Importer.material(from: data, password: pkcs12Password)
            stage(material.certificateChainPEM, role: .clientCertificate)
            stage(material.privateKeyPEM, role: .clientKey)
            certificateSummaries[.clientCertificate] = material.commonName
                ?? String(localized: "Client certificate")
            certificateSummaries[.clientKey] = String(localized: "Private key")
        } catch {
            certificateError = error.localizedDescription
        }
    }

    func removeCertificate(_ role: CertificateRole) {
        certificateSummaries[role] = nil
        pendingCertificates[role] = nil
        removedCertificates.insert(role)
    }

    func persistCertificates(for connectionId: UUID) {
        for role in removedCertificates where pendingCertificates[role] == nil {
            certificateStore.delete(role: role, for: connectionId)
        }
        for (role, pem) in pendingCertificates {
            try? certificateStore.store(pem, role: role, for: connectionId)
        }
        removedCertificates.removeAll()
        pendingCertificates.removeAll()
    }

    func cancelPKCS12() {
        pendingPKCS12 = nil
        pkcs12Password = ""
    }

    func dismissCertificateError() {
        certificateError = nil
    }

    private func adopt(_ text: String, role: CertificateRole) {
        let inspection = PEMDocument.inspect(text)
        guard !inspection.isEmpty else {
            certificateError = String(localized: "That text has no certificate or key in it. Paste the whole PEM block, including its BEGIN and END lines.")
            return
        }
        guard !inspection.usesPassphrase else {
            certificateError = String(localized: "That private key is protected by a passphrase. Remove the passphrase or import a PKCS#12 file instead.")
            return
        }

        if role == .clientKey, inspection.privateKeys.isEmpty {
            certificateError = String(localized: "That file holds a certificate, not a private key.")
            return
        }
        if role != .clientKey, inspection.certificates.isEmpty {
            certificateError = String(localized: "That file holds a private key, not a certificate.")
            return
        }

        if role == .clientCertificate, let key = inspection.privateKeys.first {
            stage(key.text + "\n", role: .clientKey)
            certificateSummaries[.clientKey] = String(localized: "Private key")
        }

        stage(text, role: role)
        certificateSummaries[role] = summary(for: role, pem: text)
    }

    private func stage(_ pem: String, role: CertificateRole) {
        pendingCertificates[role] = pem
        removedCertificates.remove(role)
    }

    private func summary(for role: CertificateRole, pem: String) -> String {
        if role == .clientKey { return String(localized: "Private key") }
        return CertificateSummary.subject(ofFirstCertificateIn: pem)
            ?? String(localized: "Certificate")
    }

    private func pickedURL(from result: Result<[URL], any Error>) -> URL? {
        switch result {
        case .success(let urls):
            return urls.first
        case .failure(let error):
            certificateError = error.localizedDescription
            return nil
        }
    }

    private func readText(at url: URL) -> String? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
