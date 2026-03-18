//
//  String+SHA256.swift
//  TablePro
//
//  SHA256 hashing helper using CryptoKit
//

import CryptoKit
import Foundation

extension String {
    /// Returns the SHA256 hash of this string as a lowercase hex string
    var sha256: String {
        let data = Data(utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
