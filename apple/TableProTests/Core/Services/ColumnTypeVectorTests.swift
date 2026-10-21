//
//  ColumnTypeVectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ColumnTypeVectorTests {
    private let classifier = ColumnTypeClassifier()

    @Test("pgvector's three types classify as vectors, with or without a dimension count", arguments: [
        "vector", "vector(1536)", "halfvec(768)", "sparsevec(1000)", "VECTOR", "halfvec", "sparsevec"
    ])
    func pgvectorTypesAreVectors(raw: String) {
        #expect(classifier.classify(rawTypeName: raw) == .vector(rawType: raw))
    }

    @Test("An array of vectors is an array whose element is a vector")
    func vectorArray() {
        #expect(
            classifier.classify(rawTypeName: "vector(3)[]")
                == .array(rawType: "vector(3)[]", element: .vector(rawType: "vector(3)"))
        )
        #expect(classifier.classify(rawTypeName: "vector(3)[]").arrayElementEditor == nil)
    }

    @Test("The dimension count is a lone number in the modifier and nothing else")
    func dimensions() {
        #expect(ColumnType.vector(rawType: "vector(1536)").vectorDimensions == 1_536)
        #expect(ColumnType.vector(rawType: "sparsevec(1000)").vectorDimensions == 1_000)
        #expect(ColumnType.vector(rawType: "vector").vectorDimensions == nil)
        #expect(ColumnType.vector(rawType: "VECTOR(3, FLOAT32)").vectorDimensions == nil)
        #expect(ColumnType.vector(rawType: "VECTOR(FLOAT, 256)").vectorDimensions == nil)
        #expect(ColumnType.vector(rawType: nil).vectorDimensions == nil)
        #expect(ColumnType.text(rawType: "varchar(3)").vectorDimensions == nil)
    }

    @Test("An emptied vector cell has no empty value to write, so it stages NULL")
    func noEmptyValue() {
        #expect(!ColumnType.vector(rawType: "vector(3)").hasEmptyValue)
    }

    @Test("A vector keeps the name the server declared and reads as a vector in the sidebar")
    func declaredNameAndBadge() {
        let declared = ColumnType.vector(rawType: "vector").declared(as: "vector(3)")
        #expect(declared == .vector(rawType: "vector(3)"))
        #expect(declared.badgeLabel == "vector")
        #expect(declared.isVectorType)
        #expect(!ColumnType.json(rawType: "jsonb").isVectorType)
    }

    @Test("A vector keeps its equality filter and is not compared with LIKE uncast")
    func filterBehavior() {
        let vector = ColumnType.vector(rawType: "vector(3)")
        #expect(ColumnTypeSQLQuoting.hasEqualityOperator(vector))
        #expect(!ColumnTypeSQLQuoting.isCharacterType(vector))
        #expect(!ColumnTypeSQLQuoting.isKnownTextLike(vector))
    }
}
