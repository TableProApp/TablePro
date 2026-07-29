//
//  PluginBundleLoaderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PluginBundleLoader.describeLoadFailure")
struct PluginBundleLoaderDescribeLoadFailureTests {
    private func makeError(_ code: Int, debug: String? = nil, failureReason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let debug { userInfo[NSDebugDescriptionErrorKey] = debug }
        if let failureReason { userInfo[NSLocalizedFailureReasonErrorKey] = failureReason }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
    }

    @Test("missing executable file reports a missing-file reason")
    func missingFile() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSFileNoSuchFileError))
        #expect(reason.localizedCaseInsensitiveContains("missing"))
        #expect(!reason.contains("Bundle failed to load executable"))
    }

    @Test("not-loadable executable reports a damaged executable")
    func notLoadable() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSExecutableNotLoadableError))
        #expect(reason.localizedCaseInsensitiveContains("loaded") || reason.localizedCaseInsensitiveContains("damaged"))
    }

    @Test("architecture mismatch names the processor architecture")
    func architectureMismatch() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSExecutableArchitectureMismatchError))
        #expect(reason.localizedCaseInsensitiveContains("architecture"))
    }

    @Test("runtime mismatch reports an incompatible runtime")
    func runtimeMismatch() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSExecutableRuntimeMismatchError))
        #expect(reason.localizedCaseInsensitiveContains("runtime"))
    }

    @Test("missing dependency reports a missing component")
    func missingDependency() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSExecutableLoadError))
        #expect(reason.localizedCaseInsensitiveContains("component"))
    }

    @Test("link error points at app or plugin incompatibility")
    func linkError() {
        let reason = PluginBundleLoader.describeLoadFailure(makeError(NSExecutableLinkError))
        #expect(reason.contains("TablePro"))
    }

    @Test("unknown code falls back to the OS-provided reason")
    func unknownCodeFallsBack() {
        let reason = PluginBundleLoader.describeLoadFailure(
            makeError(999_999, failureReason: "Custom underlying reason")
        )
        #expect(reason == "Custom underlying reason")
    }
}
