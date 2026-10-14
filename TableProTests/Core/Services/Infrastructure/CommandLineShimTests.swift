import Foundation
@testable import TablePro
import Testing

struct CommandLineShimTests {
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory().appending("CommandLineShimTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func tool(in directory: String) throws -> CommandLineShim {
        let shim = (directory as NSString).appendingPathComponent("Tablé Pro's.app/bin/tablepro")
        try FileManager.default.createDirectory(
            atPath: (shim as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: shim, contents: Data("#!/bin/sh\n".utf8))
        return CommandLineShim(
            shimPath: shim,
            linkPath: (directory as NSString).appendingPathComponent("local/bin/tablepro")
        )
    }

    private func runWithoutSudo(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.replacingOccurrences(of: "sudo ", with: "")]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("The app bundle carries an executable shim that opens TablePro by bundle id")
    func bundleCarriesTheShim() throws {
        let shim = CommandLineShim().shimPath
        #expect(shim.hasSuffix("/Contents/SharedSupport/bin/tablepro"))
        #expect(FileManager.default.isExecutableFile(atPath: shim))
        let contents = try String(contentsOfFile: shim, encoding: .utf8)
        #expect(contents.contains("exec open -b com.TablePro \"$@\""))
    }

    @Test("Nothing at the link path reads as not linked")
    func emptyPathIsNotLinked() throws {
        let tool = try tool(in: try makeDirectory())
        #expect(tool.status() == .notLinked)
    }

    @Test("The printed link command links the bundled shim, quoting every path")
    func linkCommandLinksTheShim() throws {
        let tool = try tool(in: try makeDirectory())

        #expect(try runWithoutSudo(tool.linkCommand) == 0)

        #expect(tool.status() == .linked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tool.linkPath) == tool.shimPath)
    }

    @Test("The printed unlink command removes the link")
    func unlinkCommandRemovesTheLink() throws {
        let tool = try tool(in: try makeDirectory())
        #expect(try runWithoutSudo(tool.linkCommand) == 0)

        #expect(try runWithoutSudo(tool.unlinkCommand) == 0)

        #expect(tool.status() == .notLinked)
    }

    @Test("A relative link to the shim counts as linked")
    func relativeLinkIsLinked() throws {
        let directory = try makeDirectory()
        let tool = try tool(in: directory)
        let linkDirectory = (tool.linkPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: linkDirectory, withIntermediateDirectories: true)

        try FileManager.default.createSymbolicLink(
            atPath: tool.linkPath,
            withDestinationPath: "../../Tablé Pro's.app/bin/tablepro"
        )

        #expect(tool.status() == .linked)
    }

    @Test("A file or a link that is not this app's shim is reported as another file")
    func foreignFileIsReported() throws {
        let tool = try tool(in: try makeDirectory())
        let linkDirectory = (tool.linkPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: linkDirectory, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: tool.linkPath, contents: Data("#!/bin/sh\n".utf8))
        #expect(tool.status() == .otherFile)

        try FileManager.default.removeItem(atPath: tool.linkPath)
        try FileManager.default.createSymbolicLink(atPath: tool.linkPath, withDestinationPath: "/usr/bin/true")
        #expect(tool.status() == .otherFile)
    }

    @Test("Relinking over a link to a directory replaces the link and leaves the directory alone")
    func relinkOverADirectoryLink() throws {
        let directory = try makeDirectory()
        let tool = try tool(in: directory)
        let elsewhere = (directory as NSString).appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: (tool.linkPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: tool.linkPath, withDestinationPath: elsewhere)

        #expect(try runWithoutSudo(tool.linkCommand) == 0)

        #expect(tool.status() == .linked)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
    }

    @Test("The link command stops at a real directory instead of writing into it")
    func linkCommandStopsAtADirectory() throws {
        let tool = try tool(in: try makeDirectory())
        try FileManager.default.createDirectory(atPath: tool.linkPath, withIntermediateDirectories: true)

        #expect(try runWithoutSudo(tool.linkCommand) != 0)

        #expect(try FileManager.default.contentsOfDirectory(atPath: tool.linkPath).isEmpty)
    }

    @Test("A single quote in a path cannot break out of the quoting")
    func quotingEscapesSingleQuotes() {
        #expect(CommandLineShim.quote("/Apps/Dat's.app") == "'/Apps/Dat'\\''s.app'")
    }
}
