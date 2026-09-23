//
//  LoadableExtensionLoaderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Loadable extension loader")
struct LoadableExtensionLoaderTests {
    private final class FakeHandle {
        var calls: [String] = []
        var enableAnswer = true
        var disableAnswer = false
        var failures: [String: String] = [:]

        func setLoadingEnabled(_ enabled: Bool) -> Bool {
            calls.append(enabled ? "enable" : "disable")
            return enabled ? enableAnswer : disableAnswer
        }

        func load(_ file: String, _ entryPoint: String?) -> String? {
            calls.append("load \((file as NSString).lastPathComponent)")
            return failures[(file as NSString).lastPathComponent]
        }
    }

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadableExtensionLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func library(_ name: String) throws -> LoadableExtension {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return LoadableExtension(path: url.path)
    }

    private func run(_ list: [LoadableExtension], on handle: FakeHandle, diagnosis: String? = nil) throws {
        try LoadableExtensionLoader.load(
            list,
            setLoadingEnabled: handle.setLoadingEnabled,
            loadExtension: handle.load,
            diagnoseOpenFailure: { _ in diagnosis }
        )
    }

    @Test("An empty list never touches the loading switch")
    func emptyListDoesNothing() throws {
        let handle = FakeHandle()
        try run([], on: handle)
        #expect(handle.calls.isEmpty)
    }

    @Test("Loading is opened, every file loads in list order, and loading is closed")
    func loadsInOrderBetweenTheSwitch() throws {
        let handle = FakeHandle()
        try run([try library("a.dylib"), try library("b.dylib")], on: handle)
        #expect(handle.calls == ["enable", "load a.dylib", "load b.dylib", "disable"])
    }

    @Test("The first failure stops the list and loading is still closed")
    func stopsAtFirstFailureAndCloses() throws {
        let handle = FakeHandle()
        handle.failures["a.dylib"] = "error during initialization: needs SQLite 9"
        let first = try library("a.dylib")
        #expect(throws: LoadableExtensionError.initializationFailed(
            first, detail: "The extension failed to start: needs SQLite 9"
        )) {
            try run([first, try library("b.dylib")], on: handle)
        }
        #expect(handle.calls == ["enable", "load a.dylib", "disable"])
    }

    @Test("One file listed under two spellings loads once, and the second spelling is refused")
    func sameFileTwiceIsADuplicate() throws {
        let library = try library("mod_spatialite.dylib")
        let bare = LoadableExtension(path: String(library.path.dropLast(".dylib".count)))
        let link = directory.appendingPathComponent("link.dylib")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: library.path)
        let linked = LoadableExtension(path: link.path)

        for second in [bare, linked] {
            let handle = FakeHandle()
            #expect(throws: LoadableExtensionError.duplicate(second)) {
                try run([library, second], on: handle)
            }
            #expect(handle.calls == ["enable", "load mod_spatialite.dylib", "disable"])
        }
    }

    @Test("A command a recovery suggests quotes the path as one shell word")
    func recoveryCommandsQuoteThePath() {
        let hostile = LoadableExtension(path: "/tmp/it's $(touch pwned) `id`.dylib")
        let quoted = "'/tmp/it'\\''s $(touch pwned) `id`.dylib'"
        let damaged = LoadableExtensionError.damagedSignature(hostile).recoverySuggestion ?? ""
        let quarantined = LoadableExtensionError.libraryNotLoaded(
            hostile, detail: "library load disallowed by system policy"
        ).recoverySuggestion ?? ""
        #expect(damaged.hasSuffix(" " + quoted))
        #expect(quarantined.hasSuffix(" " + quoted))
    }

    @Test("A missing file fails before SQLite is asked, and loading is still closed")
    func missingFileClosesLoading() throws {
        let handle = FakeHandle()
        let missing = LoadableExtension(path: directory.appendingPathComponent("gone.dylib").path)
        #expect(throws: LoadableExtensionError.fileNotFound(missing)) {
            try run([missing], on: handle)
        }
        #expect(handle.calls == ["enable", "disable"])
    }

    @Test("An invalid list fails before loading is opened")
    func invalidListNeverOpens() {
        let handle = FakeHandle()
        let relative = LoadableExtension(path: "vec0.dylib")
        #expect(throws: LoadableExtensionError.relativePath(relative)) {
            try run([relative], on: handle)
        }
        #expect(handle.calls.isEmpty)
    }

    @Test("A handle that will not open loading loads nothing")
    func refusedEnableLoadsNothing() throws {
        let handle = FakeHandle()
        handle.enableAnswer = false
        #expect(throws: LoadableExtensionError.loadingUnavailable) {
            try run([try library("a.dylib")], on: handle)
        }
        #expect(handle.calls == ["enable"])
    }

    @Test("A handle that will not close loading fails the connect")
    func refusedDisableFails() throws {
        let handle = FakeHandle()
        handle.disableAnswer = true
        #expect(throws: LoadableExtensionError.loadingNotClosed) {
            try run([try library("a.dylib")], on: handle)
        }
    }

    @Test("A missing entry point names the symbol SQLite looked for")
    func missingEntryPoint() throws {
        let handle = FakeHandle()
        handle.failures["renamed.dylib"] = "dlsym(0x6645e570, sqlite3_renamed_init): symbol not found"
        let item = try library("renamed.dylib")
        #expect(throws: LoadableExtensionError.entryPointNotFound(
            item, detail: "The file has no function named sqlite3_renamed_init."
        )) {
            try run([item], on: handle)
        }
    }

    @Test("A library dyld refuses reports dyld's reason for the file, not SQLite's retried path")
    func openFailureUsesDyldReason() throws {
        let handle = FakeHandle()
        handle.failures["arm.dylib"] = "dlopen(/x/arm.dylib.dylib, 0x000A): tried: '/x/arm.dylib.dylib' (no such file)"
        let item = try library("arm.dylib")
        let dyld = "dlopen(/x/arm.dylib, 0x0006): tried: '/x/arm.dylib' "
            + "(mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64')), "
            + "'/System/Volumes/Preboot/Cryptexes/OS/x/arm.dylib' (no such file)"
        #expect(throws: LoadableExtensionError.libraryNotLoaded(
            item, detail: "mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64')"
        )) {
            try run([item], on: handle, diagnosis: dyld)
        }
    }

    @Test("When the file opens on its own, SQLite's message is kept")
    func keepsSQLiteMessageWhenDiagnosisOpens() throws {
        let handle = FakeHandle()
        handle.failures["odd.dylib"] = "unable to open shared library [odd]"
        let item = try library("odd.dylib")
        #expect(throws: LoadableExtensionError.libraryNotLoaded(item, detail: "unable to open shared library [odd]")) {
            try run([item], on: handle, diagnosis: nil)
        }
    }

    @Test("dyld's reason is the one it gives for the file itself, parentheses and all")
    func dyldReasonForTheFile() {
        let message = "dlopen(/t/arm.dylib, 0x0006): tried: '/t/arm.dylib' "
            + "(mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64')), "
            + "'/private/t/arm.dylib' (no such file)"
        #expect(
            LoadableExtensionDiagnosis.dyldReason(in: message, for: "/t/arm.dylib")
                == "mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64')"
        )
        #expect(LoadableExtensionDiagnosis.dyldReason(in: "no tried list here", for: "/t/x.dylib") == "no tried list here")
    }

    @Test("A library search path dyld tries first does not hide the file's own reason")
    func dyldReasonSkipsSearchPaths() {
        let message = "dlopen(/t/text.dylib, 0x0006): tried: '/Build/Products/Debug/text.dylib' (no such file), "
            + "'/t/text.dylib' (slice is not valid mach-o file)"
        #expect(LoadableExtensionDiagnosis.dyldReason(in: message, for: "/t/text.dylib") == "slice is not valid mach-o file")
        #expect(LoadableExtensionDiagnosis.dyldReason(in: message, for: "/elsewhere.dylib") == "slice is not valid mach-o file")
    }

    @Test("Opening a file that is not a library reports dyld's own reason")
    func realOpenFailure() throws {
        let item = try library("text.dylib")
        let message = try #require(LoadableExtensionDiagnosis.openFailure(item.path))
        #expect(LoadableExtensionDiagnosis.dyldReason(in: message, for: item.path).contains("mach-o"))
    }

    @Test("Each failure has a message naming the file and a reason")
    func errorsDescribeThemselves() throws {
        let item = LoadableExtension(path: "/opt/homebrew/lib/vec0.dylib")
        let error = LoadableExtensionError.fileNotFound(item)
        #expect(error.errorDescription?.contains("vec0.dylib") == true)
        #expect(error.failureReason?.contains("/opt/homebrew/lib/vec0.dylib") == true)
        #expect(error.recoverySuggestion != nil)

        let quarantined = LoadableExtensionError.libraryNotLoaded(item, detail: "library load disallowed by system policy")
        #expect(quarantined.recoverySuggestion != nil)
    }
}
