import Foundation

nonisolated enum PEMLabel: String, CaseIterable, Sendable {
    case certificate = "CERTIFICATE"
    case pkcs8PrivateKey = "PRIVATE KEY"
    case rsaPrivateKey = "RSA PRIVATE KEY"
    case ecPrivateKey = "EC PRIVATE KEY"
    case encryptedPrivateKey = "ENCRYPTED PRIVATE KEY"

    var isPrivateKey: Bool { self != .certificate }
}

nonisolated struct PEMBlock: Equatable, Sendable {
    let label: PEMLabel
    let text: String
}

nonisolated struct PEMInspection: Equatable, Sendable {
    let certificates: [PEMBlock]
    let privateKeys: [PEMBlock]
    let usesPassphrase: Bool

    var isEmpty: Bool { certificates.isEmpty && privateKeys.isEmpty }
}

nonisolated enum PEMDocument {
    static let lineLength = 64

    static func inspect(_ text: String) -> PEMInspection {
        let found = blocks(in: text)
        return PEMInspection(
            certificates: found.filter { $0.label == .certificate },
            privateKeys: found.filter(\.label.isPrivateKey),
            usesPassphrase: found.contains { $0.label == .encryptedPrivateKey } || hasLegacyEncryptionHeader(text)
        )
    }

    static func blocks(in text: String) -> [PEMBlock] {
        var result: [PEMBlock] = []
        var current: [Substring] = []
        var openLabel: PEMLabel?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let label = openLabel {
                current.append(line)
                guard trimmed == endMarker(for: label) else { continue }
                result.append(PEMBlock(label: label, text: current.joined(separator: "\n")))
                current = []
                openLabel = nil
                continue
            }

            guard let label = label(forBeginMarker: trimmed) else { continue }
            openLabel = label
            current = [line]
        }

        return result
    }

    static func encode(_ der: Data, as label: PEMLabel) -> String {
        let body = der.base64EncodedString()
        var lines: [String] = [beginMarker(for: label)]
        var index = body.startIndex

        while index < body.endIndex {
            let end = body.index(index, offsetBy: lineLength, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[index..<end]))
            index = end
        }

        lines.append(endMarker(for: label))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func beginMarker(for label: PEMLabel) -> String {
        "-----BEGIN \(label.rawValue)-----"
    }

    private static func endMarker(for label: PEMLabel) -> String {
        "-----END \(label.rawValue)-----"
    }

    private static func label(forBeginMarker line: String) -> PEMLabel? {
        PEMLabel.allCases.first { beginMarker(for: $0) == line }
    }

    private static func hasLegacyEncryptionHeader(_ text: String) -> Bool {
        text.contains("Proc-Type: 4,ENCRYPTED") || text.contains("Proc-Type:4,ENCRYPTED")
    }
}
