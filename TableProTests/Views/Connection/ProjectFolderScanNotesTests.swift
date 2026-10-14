//
//  ProjectFolderScanNotesTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct ProjectFolderScanNotesTests {
    private func renderedHeight(_ notes: [String]) -> Int {
        let renderer = ImageRenderer(content: ProjectFolderScanNotes(notes: notes))
        renderer.proposedSize = ProposedViewSize(width: 480, height: nil)
        renderer.scale = 1
        return renderer.cgImage?.height ?? 0
    }

    @Test("Every note keeps a line of its own, so a third one is not clipped")
    func thirdNoteIsShown() {
        let two = ["Looks like a placeholder value", "Some values are set outside this file"]
        let three = two + ["No published port, may be unreachable"]

        #expect(renderedHeight(two) > 0)
        #expect(renderedHeight(three) > renderedHeight(two))
    }
}
