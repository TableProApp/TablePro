//
//  VectorLiteralTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct VectorLiteralTests {
    @Test("A dense vector reads in the spelling pgvector prints, indices from 1")
    func denseVectorParses() throws {
        let vector = try #require(VectorLiteral.parse("[1,2.5,-3e-05]"))
        #expect(vector.dimensions == 3)
        #expect(!vector.isSparse)
        #expect(vector.elements.map(\.index) == [1, 2, 3])
        #expect(vector.elements.map(\.text) == ["1", "2.5", "-3e-05"])
    }

    @Test("Spaces pgvector accepts around brackets and elements are read past")
    func whitespaceIsAccepted() throws {
        let vector = try #require(VectorLiteral.parse("  [ 1 , +2 , .5, 5. ]\n"))
        #expect(vector.elements.map(\.text) == ["1", "+2", ".5", "5."])
    }

    @Test("What pgvector refuses is no vector", arguments: [
        "[1,,2]", "[NaN]", "[1, inf]", "", "1,2,3", "[1,2", "[a]", "{1:1,1:2}/3", "{4:1}/3", "{1:1}", "{1:1}/0"
    ])
    func invalidTextIsNoVector(text: String) {
        #expect(VectorLiteral.parse(text) == nil)
    }

    @Test("An empty bracket pair is a vector of no dimensions, so a length check still sees it")
    func emptyDenseVector() throws {
        let vector = try #require(VectorLiteral.parse("[]"))
        #expect(vector.dimensions == 0)
        #expect(vector.elements.isEmpty)
    }

    @Test("A sparse vector takes its dimensions from after the slash and lists its entries in order")
    func sparseVectorParses() throws {
        let vector = try #require(VectorLiteral.parse("{3:0.5, 1:2}/5"))
        #expect(vector.isSparse)
        #expect(vector.dimensions == 5)
        #expect(vector.elements == [
            VectorLiteral.Element(index: 1, text: "2"),
            VectorLiteral.Element(index: 3, text: "0.5")
        ])
        let empty = try #require(VectorLiteral.parse("{}/3"))
        #expect(empty.dimensions == 3)
    }

    @Test("Copy as JSON gives a dense vector as an array and a sparse one as an object by index")
    func jsonText() throws {
        let dense = try #require(VectorLiteral.parse("[1,+2,.5,5.,-3e-05]"))
        let sparse = try #require(VectorLiteral.parse("{1:2,3:0.5}/5"))
        let empty = try #require(VectorLiteral.parse("[]"))
        #expect(dense.jsonText == "[1,2,0.5,5,-3e-5]")
        #expect(sparse.jsonText == #"{"1":2,"3":0.5}"#)
        #expect(empty.jsonText == "[]")
    }

    @Test("The grid summary shows the first three elements and the dimension count")
    func denseSummary() {
        #expect(VectorLiteral.summary(of: "[0.0123,-0.0456,0.0789,0.1,0.2]") == "[0.0123, -0.0456, 0.0789, …] 5 dims")
        #expect(VectorLiteral.summary(of: "[1,2,3]") == "[1, 2, 3] 3 dims")
        #expect(VectorLiteral.summary(of: "[7]") == "[7] 1 dim")
        #expect(VectorLiteral.summary(of: "[]") == "[] 0 dims")
    }

    @Test("A 1,536-dimension value summarises without listing it")
    func longVectorSummary() {
        let literal = "[" + (1...1_536).map { "0.\($0)" }.joined(separator: ",") + "]"
        #expect(VectorLiteral.summary(of: literal) == "[0.1, 0.2, 0.3, …] 1536 dims")
    }

    @Test("A sparse summary counts the declared dimensions, not the entries")
    func sparseSummary() {
        #expect(VectorLiteral.summary(of: "{1:2,3:0.5}/1000") == "{1:2, 3:0.5} 1000 dims")
        #expect(VectorLiteral.summary(of: "{1:2,3:0.5,7:1,9:4}/10") == "{1:2, 3:0.5, 7:1, …} 10 dims")
        #expect(VectorLiteral.summary(of: "{}/3") == "{} 3 dims")
    }

    @Test("Text that is not shaped like a vector keeps its own display", arguments: [
        "hello", "[1,,2]", "[[1,2],[3]]", "[a,b]", "{1:2}", "{x:1}/3", "[1,2", "{\"a\":1}"
    ])
    func nonVectorHasNoSummary(text: String) {
        #expect(VectorLiteral.summary(of: text) == nil)
        #expect(!VectorLiteral.isVectorText(text))
    }
}
