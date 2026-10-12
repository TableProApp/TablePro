//
//  DocumentPathTests.swift
//  TableProDocumentPathTests
//

import Foundation
import Testing

@testable import TableProDocumentPath

@Suite("Document Path")
struct DocumentPathTests {
    @Test("A plain dotted path walks dictionaries")
    func walksDictionaries() {
        let document: [String: Any] = ["address": ["city": "Lisbon"]]
        #expect(DocumentPath.value(in: document, atPath: "address.city") as? String == "Lisbon")
    }

    @Test("A path no key answers is nil")
    func missingKeyIsNil() {
        let document: [String: Any] = ["address": ["city": "Lisbon"]]
        #expect(DocumentPath.value(in: document, atPath: "address.zip") == nil)
        #expect(DocumentPath.value(in: document, atPath: "contact.city") == nil)
    }

    @Test("An array is a container, so the remaining keys read from every element")
    func readsAcrossArrayElements() {
        let document: [String: Any] = ["variants": [["sku": "A1"], ["sku": "B2"]]]
        let values = DocumentPath.value(in: document, atPath: "variants.sku") as? [Any]
        #expect(values?.compactMap { $0 as? String } == ["A1", "B2"])
    }

    @Test("An element missing the key keeps its place, so sibling columns stay aligned")
    func missingElementKeepsItsPlace() {
        let document: [String: Any] = ["variants": [["qty": 3], ["sku": "B2", "qty": 5]]]
        let skus = DocumentPath.value(in: document, atPath: "variants.sku") as? [Any]
        let quantities = DocumentPath.value(in: document, atPath: "variants.qty") as? [Any]
        #expect(skus?.count == 2)
        #expect(skus?[0] is NSNull)
        #expect(skus?[1] as? String == "B2")
        #expect(quantities?.count == 2)
    }

    @Test("A key no element carries is nil rather than an array of nulls")
    func absentAcrossEveryElementIsNil() {
        let document: [String: Any] = ["variants": [["qty": 3], ["qty": 5]]]
        #expect(DocumentPath.value(in: document, atPath: "variants.sku") == nil)
    }

    @Test("An empty array answers nothing")
    func emptyArrayIsNil() {
        let document: [String: Any] = ["variants": []]
        #expect(DocumentPath.value(in: document, atPath: "variants.sku") == nil)
    }

    @Test("A path keeps walking through an array it meets on the way")
    func walksThroughAnArrayMidPath() {
        let document: [String: Any] = ["variants": [["price": ["eur": 10]], ["price": ["eur": 20]]]]
        let values = DocumentPath.value(in: document, atPath: "variants.price.eur") as? [Any]
        #expect(values?.compactMap { $0 as? Int } == [10, 20])
    }

    @Test("An empty path answers the whole document")
    func emptyPathAnswersTheDocument() {
        let document: [String: Any] = ["id": "1"]
        #expect((DocumentPath.value(in: document, atPath: "") as? [String: Any])?["id"] as? String == "1")
    }

    @Test("A scalar partway through the path stops it")
    func scalarStopsThePath() {
        let document: [String: Any] = ["address": "Lisbon"]
        #expect(DocumentPath.value(in: document, atPath: "address.city") == nil)
    }
}
