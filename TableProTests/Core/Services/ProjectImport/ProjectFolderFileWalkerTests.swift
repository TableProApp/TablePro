//
//  ProjectFolderFileWalkerTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Project Folder File Walker")
struct ProjectFolderFileWalkerTests {
    private let root: URL
    private let outside: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProjectWalkerTests-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func walk() -> [String] {
        ProjectFolderFileWalker.walk(root: root).map(\.relativePath)
    }

    @Test("A dotenv file at the project root is found")
    func testFindsRootDotenv() throws {
        try write("DATABASE_URL=postgres://localhost/app", to: ".env")
        #expect(walk().contains(".env"))
    }

    @Test("Excluded directories are never descended into")
    func testExcludedDirectories() throws {
        try write("DATABASE_URL=postgres://localhost/app", to: ".env")
        try write("DATABASE_URL=postgres://localhost/pkg", to: "node_modules/pkg/.env")
        try write("DATABASE_URL=postgres://localhost/vendored", to: "vendor/thing/.env")
        let found = walk()
        #expect(found == [".env"])
    }

    @Test("A dotenv symlink pointing outside the project is never read")
    func testSymlinkedFileRejected() throws {
        let target = outside.appendingPathComponent("secret.txt")
        try "SECRET=value".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".env"),
            withDestinationURL: target
        )
        #expect(walk().isEmpty)
    }

    @Test("A symlinked directory is not descended into")
    func testSymlinkedDirectoryNotFollowed() throws {
        let nested = outside.appendingPathComponent("hidden")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "DATABASE_URL=postgres://localhost/x"
            .write(to: nested.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: nested
        )
        #expect(walk().isEmpty)
    }

    @Test("Files over the size cap are skipped")
    func testFileSizeCap() throws {
        let oversized = String(repeating: "A", count: ProjectFolderFileWalker.maxFileSize + 1024)
        try write(oversized, to: ".env")
        #expect(walk().isEmpty)
    }

    @Test("Files deeper than the depth cap are skipped")
    func testDepthCap() throws {
        try write("DATABASE_URL=postgres://localhost/shallow", to: "a/.env")
        try write("DATABASE_URL=postgres://localhost/deep", to: "a/b/c/d/e/.env")
        let found = walk()
        #expect(found.contains("a/.env"))
        #expect(!found.contains("a/b/c/d/e/.env"))
    }

    @Test("Placeholder dotenv files never reach the scanner")
    func testPlaceholderFileSkipped() throws {
        try write("DATABASE_URL=postgres://user:pass@localhost/app", to: ".env.example")
        #expect(walk().isEmpty)
    }

    @Test("Sensitive home directories are denied by absolute path")
    func testDenyList() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(ProjectFolderFileWalker.isDenied(home + "/.ssh/config"))
        #expect(ProjectFolderFileWalker.isDenied(home + "/.aws/credentials"))
        #expect(ProjectFolderFileWalker.isDenied("/etc/passwd"))
        #expect(!ProjectFolderFileWalker.isDenied(home + "/Developer/project/.env"))
    }
}
