//
//  NavicatCipherTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("NavicatCipher")
struct NavicatCipherTests {
    @Test("Decrypts a Navicat 12+ (AES) password")
    func decryptsV2GoldenVector() {
        #expect(NavicatCipher.decrypt("B75D320B6211468D63EB3B67C9E85933") == "This is a test")
    }

    @Test("Decrypts a Navicat 11 (Blowfish) password")
    func decryptsV1GoldenVector() {
        #expect(NavicatCipher.decrypt("0EA71F51DD37BFB60CCBA219BE3A") == "This is a test")
    }

    @Test("Decrypts a Navicat 11 password whose length is a multiple of the AES block size")
    func decryptsV1PasswordWithBlockAlignedLength() {
        #expect(NavicatCipher.decrypt("2E6C8CF471EB0268D3239A0AD531F1B1") == "Sup3rSecret!Pass")
    }

    @Test("Returns nil for an empty string")
    func returnsNilForEmptyString() {
        #expect(NavicatCipher.decrypt("") == nil)
    }

    @Test("Returns nil for odd-length hex")
    func returnsNilForOddLengthHex() {
        #expect(NavicatCipher.decrypt("ABC") == nil)
    }

    @Test("Returns nil for non-hex input")
    func returnsNilForNonHexInput() {
        #expect(NavicatCipher.decrypt("ZZZZ") == nil)
    }
}
