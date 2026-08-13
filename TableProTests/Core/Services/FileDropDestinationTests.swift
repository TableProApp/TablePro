//
//  FileDropDestinationTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("File drop destination")
@MainActor
struct FileDropDestinationTests {
    @Test("A SQL file is openable")
    func sqlFileIsOpenable() {
        #expect(FileDropDestination.isOpenable(URL(fileURLWithPath: "/tmp/report.sql")))
    }

    @Test("A binary is refused")
    func binaryIsRefused() {
        #expect(FileDropDestination.isOpenable(URL(fileURLWithPath: "/tmp/photo.jpeg")) == false)
    }

    @Test("A non-file URL is refused")
    func remoteURLIsRefused() {
        guard let url = URL(string: "https://example.com/report.sql") else {
            Issue.record("could not build the test URL")
            return
        }
        #expect(FileDropDestination.isOpenable(url) == false)
    }

    @Test("An empty pasteboard yields nothing")
    func emptyPasteboardYieldsNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.TablePro.tests.filedrop.empty"))
        pasteboard.clearContents()
        #expect(FileDropDestination.acceptedURLs(from: pasteboard).isEmpty)
    }

    @Test("A pasteboard of mixed files yields only the openable ones")
    func mixedPasteboardIsFiltered() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.TablePro.tests.filedrop.mixed"))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/report.sql") as NSURL,
            URL(fileURLWithPath: "/tmp/photo.jpeg") as NSURL
        ])
        let accepted = FileDropDestination.acceptedURLs(from: pasteboard)
        #expect(accepted.count == 1)
        #expect(accepted.first?.pathExtension == "sql")
    }
}
