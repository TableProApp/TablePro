//
//  CLIExecutableFinderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CLIExecutableFinder")
struct CLIExecutableFinderTests {
    @Test("findExecutable returns nil for a nonexistent binary")
    func findExecutableNonexistent() {
        #expect(CLIExecutableFinder.findExecutable("__tablepro_nonexistent_binary_xyz__") == nil)
    }

    @Test("findExecutable resolves a system binary on PATH")
    func findExecutableSystemBinary() {
        #expect(CLIExecutableFinder.findExecutable("ls") != nil)
    }
}
