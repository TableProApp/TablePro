//
//  LoadableExtensionPreflightTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Loadable extension preflight")
struct LoadableExtensionPreflightTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadableExtensionPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ name: String, contents: Data = Data("x".utf8)) throws -> String {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url.path
    }

    @Test("A list of absolute paths with valid entry points passes")
    func validListPasses() throws {
        try LoadableExtensionPreflight.validate([
            LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib"),
            LoadableExtension(path: "~/vec0.dylib", entryPoint: "sqlite3_vec_init")
        ])
    }

    @Test("Relative paths, bare names and dyld search tokens are refused", arguments: [
        "vec0.dylib",
        "mod_spatialite",
        "lib/vec0.dylib",
        "@rpath/vec0.dylib",
        "@executable_path/vec0.dylib"
    ])
    func refusesPathsDyldWouldSearch(path: String) {
        let item = LoadableExtension(path: path)
        #expect(throws: LoadableExtensionError.relativePath(item)) {
            try LoadableExtensionPreflight.validate([item])
        }
    }

    @Test("An entry with no file is refused")
    func refusesEmptyPath() {
        #expect(throws: LoadableExtensionError.missingPath) {
            try LoadableExtensionPreflight.validate([LoadableExtension(path: "  ")])
        }
    }

    @Test("A path longer than dyld accepts is refused, never shortened to one it accepts")
    func refusesLongPath() {
        let item = LoadableExtension(path: "/" + String(repeating: "a", count: 1_100))
        #expect(item.expandedPath.utf8.count == 1_101)
        #expect(throws: LoadableExtensionError.pathTooLong(item)) {
            try LoadableExtensionPreflight.validate([item])
        }
        let home = LoadableExtension(path: "~/" + String(repeating: "a", count: 1_100))
        #expect(throws: LoadableExtensionError.pathTooLong(home)) {
            try LoadableExtensionPreflight.validate([home])
        }
    }

    @Test("Only the current user's home expands; another user's is not a full path")
    func expandsOnlyOwnHome() {
        #expect(LoadableExtension(path: "~").expandedPath == NSHomeDirectory())
        let other = LoadableExtension(path: "~root/vec0.dylib")
        #expect(throws: LoadableExtensionError.relativePath(other)) {
            try LoadableExtensionPreflight.validate([other])
        }
    }

    @Test("An entry point that is not a C identifier is refused", arguments: [
        "sqlite3 vec init", "1init", "init()", "sqlite3_vec_init;", "init-vec"
    ])
    func refusesInvalidEntryPoint(entryPoint: String) {
        let item = LoadableExtension(path: "/x/vec0.dylib", entryPoint: entryPoint)
        #expect(throws: LoadableExtensionError.invalidEntryPoint(item)) {
            try LoadableExtensionPreflight.validate([item])
        }
    }

    @Test("The same file with the same entry point twice is refused, even spelled two ways")
    func refusesDuplicates() {
        let home = NSHomeDirectory()
        let first = LoadableExtension(path: "~/vec0.dylib")
        let second = LoadableExtension(path: home + "/vec0.dylib")
        #expect(throws: LoadableExtensionError.duplicate(second)) {
            try LoadableExtensionPreflight.validate([first, second])
        }
    }

    @Test("The same file with two entry points is two extensions")
    func allowsSameFileWithDifferentEntryPoints() throws {
        try LoadableExtensionPreflight.validate([
            LoadableExtension(path: "/x/vec0.dylib", entryPoint: "sqlite3_vec_init"),
            LoadableExtension(path: "/x/vec0.dylib", entryPoint: "sqlite3_vec_numpy_init")
        ])
    }

    @Test("C identifiers")
    func identifiers() {
        let cases: [(name: String, expected: Bool)] = [
            ("sqlite3_vec_init", true), ("_init", true), ("Init2", true),
            ("", false), ("2init", false), ("é_init", false), ("a b", false)
        ]
        for testCase in cases {
            #expect(LoadableExtensionPreflight.isCIdentifier(testCase.name) == testCase.expected, "\(testCase.name)")
        }
    }

    @Test("An existing file resolves to itself")
    func resolvesExistingFile() throws {
        let path = try file("vec0.dylib")
        #expect(try LoadableExtensionPreflight.resolveFile(for: LoadableExtension(path: path)) == path)
    }

    @Test("A path without .dylib resolves to the .dylib file beside it, as SQLite does")
    func resolvesWithDylibSuffix() throws {
        let path = try file("mod_spatialite.dylib")
        let bare = String(path.dropLast(".dylib".count))
        #expect(try LoadableExtensionPreflight.resolveFile(for: LoadableExtension(path: bare)) == path)
    }

    @Test("A missing file and a folder are refused before SQLite sees them")
    func refusesMissingFileAndFolder() throws {
        let missing = LoadableExtension(path: directory.appendingPathComponent("nope.dylib").path)
        #expect(throws: LoadableExtensionError.fileNotFound(missing)) {
            try LoadableExtensionPreflight.resolveFile(for: missing)
        }
        let folder = LoadableExtension(path: directory.path)
        #expect(throws: LoadableExtensionError.notAFile(folder)) {
            try LoadableExtensionPreflight.resolveFile(for: folder)
        }
    }

    @Test("A signed library changed after signing is refused; an intact or unsigned one is not")
    func refusesDamagedSignature() throws {
        var library = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        let intact = try file("intact", contents: library)
        for offset in stride(from: 20_000, to: library.count, by: 16_384) {
            library[offset] ^= 0xFF
        }
        let tampered = try file("tampered", contents: library)
        let unsigned = try file("unsigned.dylib")

        #expect(!LoadableExtensionPreflight.hasDamagedSignature(intact))
        #expect(!LoadableExtensionPreflight.hasDamagedSignature(unsigned))
        #expect(LoadableExtensionPreflight.hasDamagedSignature(tampered))

        let item = LoadableExtension(path: tampered)
        #expect(throws: LoadableExtensionError.damagedSignature(item)) {
            try LoadableExtensionPreflight.resolveFile(for: item)
        }
    }
}
