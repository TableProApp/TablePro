//
//  TOTPGenerator.swift
//  TablePro
//

import CryptoKit
import Foundation

internal struct TOTPGenerator {
    enum Algorithm {
        case sha1, sha256, sha512
    }

    let secret: Data
    let algorithm: Algorithm
    let digits: Int
    let period: Int

    init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    /// Generate the TOTP code for the given date.
    func generate(at date: Date = Date()) -> String {
        let timestamp = UInt64(date.timeIntervalSince1970)
        let counter = timestamp / UInt64(period)

        // Convert counter to 8-byte big-endian
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: 8)

        // Compute HMAC
        let hmac = computeHmac(key: secret, message: counterData)

        // Dynamic truncation
        let offset = Int(hmac[hmac.count - 1] & 0x0F)
        let truncated = (UInt32(hmac[offset]) & 0x7F) << 24
            | UInt32(hmac[offset + 1]) << 16
            | UInt32(hmac[offset + 2]) << 8
            | UInt32(hmac[offset + 3])

        // Modulo and zero-pad
        var divisor: UInt32 = 1
        for _ in 0..<digits {
            divisor *= 10
        }
        let code = truncated % divisor

        return String(format: "%0\(digits)d", code)
    }

    /// Seconds remaining in the current TOTP period.
    func secondsRemaining(at date: Date = Date()) -> Int {
        let elapsed = Int(date.timeIntervalSince1970) % period
        return period - elapsed
    }

    /// Create a generator from a base32-encoded secret string.
    static func fromBase32Secret(
        _ secretString: String,
        algorithm: Algorithm = .sha1,
        digits: Int = 6,
        period: Int = 30
    ) -> TOTPGenerator? {
        guard let secretData = Base32.decode(secretString), !secretData.isEmpty else {
            return nil
        }
        return TOTPGenerator(secret: secretData, algorithm: algorithm, digits: digits, period: period)
    }

    // MARK: - Private

    private func computeHmac(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        switch algorithm {
        case .sha1:
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey)
            return Data(mac)
        case .sha256:
            let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
            return Data(mac)
        case .sha512:
            let mac = HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey)
            return Data(mac)
        }
    }
}
