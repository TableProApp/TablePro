import Foundation
import TableProProcess
import Testing

struct ProcessEnvironmentTests {
    private let parent = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/alice",
        "LANG": "en_US.UTF-8",
        "GIT_SSH_COMMAND": "touch /tmp/pwned",
        "GIT_EXEC_PATH": "/tmp/planted",
        "GZIP": "-1v",
        "PYTHONPATH": "/tmp/planted",
        "PGHOST": "attacker.example",
        "CSQL_PROXY_CREDENTIALS_FILE": "/tmp/other.json",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
    ]

    @Test("The minimal environment keeps the session basics and drops every tool's own variables")
    func minimalDropsToolVariables() {
        #expect(ProcessEnvironment.minimal(from: parent) == [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/alice",
            "LANG": "en_US.UTF-8",
        ])
    }

    @Test("A named extra is kept only when the parent has it")
    func minimalKeepsNamedExtras() {
        let environment = ProcessEnvironment.minimal(keeping: ["SSH_AUTH_SOCK", "DISPLAY"], from: parent)
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(environment["DISPLAY"] == nil)
    }

    @Test("Inherited drops only the names given")
    func inheritedRemovesNames() {
        let environment = ProcessEnvironment.inherited(removing: ["GIT_EXEC_PATH"], from: parent)
        #expect(environment["GIT_EXEC_PATH"] == nil)
        #expect(environment["GIT_SSH_COMMAND"] == "touch /tmp/pwned")
    }

    @Test("Tool folders are appended and a relative PATH entry is dropped")
    func toolSearchPathsAreAbsolute() {
        let environment = ProcessEnvironment.addingToolSearchPaths(to: ["PATH": ".::/custom/bin:relative"])
        #expect(environment["PATH"] == "/custom/bin:" + ProcessEnvironment.toolSearchPaths.joined(separator: ":"))
    }

    @Test("A lookup returns an absolute path and never a name with a slash or a folder")
    func executableLookup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tablepro-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("tptool")
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("adir"), withIntermediateDirectories: true)

        let environment = ["PATH": ".:\(folder.path)"]
        #expect(ProcessEnvironment.executable(named: "tptool", in: environment) == tool.path)
        #expect(ProcessEnvironment.executable(named: "adir", in: environment) == nil)
        #expect(ProcessEnvironment.executable(named: "\(folder.lastPathComponent)/tptool", in: ["PATH": FileManager.default.temporaryDirectory.path]) == nil)
        #expect(ProcessEnvironment.executable(named: "tptool", in: ["PATH": "."]) == nil)
    }
}
