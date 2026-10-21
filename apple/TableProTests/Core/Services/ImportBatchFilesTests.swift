//
//  ImportBatchFilesTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A folder chosen in Import Data… gives the files directly inside it that a row format reads, in Finder's order,
/// and names what it leaves out.
struct ImportBatchFilesTests {
    private let options = [
        ImportFormatOption(id: "sql", name: "SQL", acceptedFileExtensions: ["sql", "gz"]),
        ImportFormatOption(id: "csv", name: "CSV", acceptedFileExtensions: ["csv", "tsv"]),
        ImportFormatOption(id: "json", name: "JSON", acceptedFileExtensions: ["json", "jsonl"]),
    ]

    private func readsRows(_ formatId: String) -> Bool {
        formatId != "sql"
    }

    private func makeFolder(_ names: [String], subfolders: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batch-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data("id\n1\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        for name in subfolders {
            let sub = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("id\n1\n".utf8).write(to: sub.appendingPathComponent("nested.csv"))
        }
        return folder
    }

    @Test("A folder gives its row files in Finder's order, with the format each extension names")
    func folderGivesRowFilesInOrder() throws {
        let folder = try makeFolder(["orders10.csv", "orders2.csv", "people.json", "notes.tsv"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let resolution = ImportBatchFiles.resolve([folder], among: options, readsRows: readsRows)

        #expect(resolution.files.map(\.url.lastPathComponent) == ["notes.tsv", "orders2.csv", "orders10.csv", "people.json"])
        #expect(resolution.files.map(\.formatId) == ["csv", "csv", "csv", "json"])
        #expect(resolution.leftOut.isEmpty)
    }

    @Test("A dump and a file no format reads are left out by name, hidden files and subfolders are skipped")
    func leavesOutWhatNoRowFormatReads() throws {
        let folder = try makeFolder(["schema.sql", "readme.md", ".hidden.csv", "orders.csv"], subfolders: ["archive"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let resolution = ImportBatchFiles.resolve([folder], among: options, readsRows: readsRows)

        #expect(resolution.files.map(\.url.lastPathComponent) == ["orders.csv"])
        #expect(resolution.leftOut.map(\.lastPathComponent) == ["readme.md", "schema.sql"])
    }

    @Test("Files chosen together keep their order, and a file named twice imports once")
    func filesKeepTheirOrder() throws {
        let folder = try makeFolder(["b.csv", "a.json"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("b.csv")
        let second = folder.appendingPathComponent("a.json")

        let resolution = ImportBatchFiles.resolve([first, second, first], among: options, readsRows: readsRows)

        #expect(resolution.files.map(\.url.lastPathComponent) == ["b.csv", "a.json"])
    }
}
