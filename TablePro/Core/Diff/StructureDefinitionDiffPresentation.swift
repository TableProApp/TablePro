//
//  StructureDefinitionDiffPresentation.swift
//  TablePro
//

import Foundation

internal struct StructureDefinitionDiffInput: Equatable, Sendable {
    let sourceLines: [String]
    let targetLines: [String]
}

internal struct StructureDefinitionDiffPresentation: Equatable, Sendable {
    let input: StructureDefinitionDiffInput
    let pairs: [DiffPair]

    init(input: StructureDefinitionDiffInput) {
        self.input = input
        pairs = DiffComputer.computeSplit(before: input.targetLines, after: input.sourceLines)
    }

    @concurrent
    static func load(_ input: StructureDefinitionDiffInput) async -> StructureDefinitionDiffPresentation {
        StructureDefinitionDiffPresentation(input: input)
    }

    func isCurrent(for input: StructureDefinitionDiffInput) -> Bool {
        self.input == input
    }
}
