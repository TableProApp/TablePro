import Foundation
@testable import TablePro
import Testing

struct CommandLineShimTests {
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory().appending("CommandLineShimTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func tool(
        in directory: String,
        isOnReadOnlyVolume: @escaping @Sendable (URL) -> Bool = { CommandLineShim.isOnReadOnlyVolume($0) }
    ) throws -> CommandLineShim {
        let shim = (directory as NSString).appendingPathComponent("Tablé Pro's.app/bin/tablepro")
        try FileManager.default.createDirectory(
            atPath: (shim as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: shim, contents: Data("#!/bin/sh\n".utf8))
        return CommandLineShim(
            shimPath: shim,
            linkPath: (directory as NSString).appendingPathComponent("local/bin/tablepro"),
            isOnReadOnlyVolume: isOnReadOnlyVolume
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

    private func makeExecutable(atPath path: String, contents: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func runCapturingOutput(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test("Through a link, the bundled shim hands every argument to its own bundle's tablepro-cli")
    func bundledShimRunsTheBundledCommand() throws {
        let bundled = CommandLineShim().shimPath
        #expect(bundled.hasSuffix("/Contents/SharedSupport/bin/tablepro"))
        #expect(FileManager.default.isExecutableFile(atPath: bundled))

        let directory = try makeDirectory()
        let app = (directory as NSString).appendingPathComponent("Copy of TablePro.app/Contents")
        let shim = (app as NSString).appendingPathComponent("SharedSupport/bin/tablepro")
        try FileManager.default.createDirectory(
            atPath: (shim as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: bundled, toPath: shim)
        try makeExecutable(
            atPath: (app as NSString).appendingPathComponent("MacOS/tablepro-cli"),
            contents: "#!/bin/sh\nprintf '%s\\n' \"$@\"\n"
        )
        let link = (directory as NSString).appendingPathComponent("bin/tablepro")
        try FileManager.default.createDirectory(
            atPath: (link as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: shim)

        for arguments in [["--help"], ["--version"], ["help"], ["query", "-c", "My DB", "SELECT 1"]] {
            let result = try runCapturingOutput(link, arguments: arguments)
            #expect(result.status == 0)
            #expect(result.output == arguments.map { $0 + "\n" }.joined())
        }
    }

    @Test("On a read-only volume no link line is offered, and a link already made can still be removed")
    func readOnlyVolumeWithholdsTheLinkLine() throws {
        let directory = try makeDirectory()
        let shimPath = (directory as NSString).appendingPathComponent("Tablé Pro's.app/bin/tablepro")
        let tool = try tool(in: directory, isOnReadOnlyVolume: { $0.path == shimPath })

        #expect(tool.command(for: .notLinked) == nil)
        #expect(tool.command(for: .otherFile) == nil)
        #expect(tool.command(for: .linked) == tool.unlinkCommand)
    }

    @Test("On a writable volume the link line is offered until the link exists")
    func writableVolumeOffersTheLinkLine() throws {
        let tool = try tool(in: try makeDirectory())

        #expect(tool.command(for: .notLinked) == tool.linkCommand)
        #expect(tool.command(for: .otherFile) == tool.linkCommand)
        #expect(tool.command(for: .linked) == tool.unlinkCommand)
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
        #expect(CommandLineShim.quote("/Apps/Dat'\u{301}s.app") == "'/Apps/Dat'\\''\u{301}s.app'")
    }

    @Test("A NUL in a path is shown escaped rather than put raw into the line")
    func quotingShowsANulEscaped() {
        #expect(CommandLineShim.quote("/Apps/a\u{0}b.app") == #"$'/Apps/a\x00b.app'"#)
    }
}
