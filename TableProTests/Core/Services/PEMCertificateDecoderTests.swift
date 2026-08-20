//
//  PEMCertificateDecoderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PEM certificate decoder")
struct PEMCertificateDecoderTests {
    private static let derBytes = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x00])

    private static func pemDocument(body: String) -> String {
        """
        -----BEGIN CERTIFICATE-----
        \(body)
        -----END CERTIFICATE-----
        """
    }

    @Test("Decodes a PEM block back to its DER bytes")
    func decodesPEM() {
        let pem = Self.pemDocument(body: Self.derBytes.base64EncodedString())
        #expect(PEMCertificateDecoder.firstCertificateDER(inPEM: pem) == Self.derBytes)
    }

    @Test("Joins a base64 body wrapped across several lines")
    func decodesWrappedBody() {
        let base64 = Data(repeating: 0xAB, count: 120).base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }.joined(separator: "\n")

        let decoded = PEMCertificateDecoder.firstCertificateDER(inPEM: Self.pemDocument(body: wrapped))
        #expect(decoded == Data(repeating: 0xAB, count: 120))
    }

    @Test("Takes only the first certificate of a chain file")
    func decodesFirstOfChain() {
        let first = Data(repeating: 0x01, count: 16)
        let second = Data(repeating: 0x02, count: 16)
        let chain = Self.pemDocument(body: first.base64EncodedString())
            + "\n"
            + Self.pemDocument(body: second.base64EncodedString())

        #expect(PEMCertificateDecoder.firstCertificateDER(inPEM: chain) == first)
    }

    @Test("Rejects a truncated block with no end marker")
    func rejectsTruncatedBlock() {
        let truncated = "-----BEGIN CERTIFICATE-----\n\(Self.derBytes.base64EncodedString())\n"
        #expect(PEMCertificateDecoder.firstCertificateDER(inPEM: truncated) == nil)
    }

    @Test("Rejects text carrying no certificate block")
    func rejectsPlainText() {
        #expect(PEMCertificateDecoder.firstCertificateDER(inPEM: "not a certificate") == nil)
        #expect(PEMCertificateDecoder.firstCertificateDER(inPEM: "") == nil)
    }

    @Test("Passes DER through untouched")
    func passesDERThrough() {
        #expect(PEMCertificateDecoder.certificateDER(from: Self.derBytes) == Self.derBytes)
    }

    @Test("A file that announces a certificate but cannot be decoded yields nil")
    func malformedPEMFileYieldsNil() {
        let malformed = Data("-----BEGIN CERTIFICATE-----\nnot base64 !!!\n".utf8)
        #expect(PEMCertificateDecoder.certificateDER(from: malformed) == nil)
    }
}
