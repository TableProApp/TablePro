import Darwin
import Foundation
import Security

struct HanaHelperTrust: Sendable {
    typealias RunningCodeCheck = @Sendable (_ processIdentifier: pid_t, _ requirement: String) throws -> Void

    static let executableName = "tablepro-hana-helper"
    static let host = HanaHelperTrust(signingTeam: runningHostTeam(), admitsUnsignedHost: isDevelopmentBuild)

    private static let staticValidationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    private static let dynamicValidationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    let signingTeam: String?
    let admitsUnsignedHost: Bool
    private let checkRunningCode: RunningCodeCheck

    init(
        signingTeam: String?,
        admitsUnsignedHost: Bool,
        checkRunningCode: @escaping RunningCodeCheck = { try HanaHelperTrust.checkRunningCode(processIdentifier: $0, requirement: $1) }
    ) {
        self.signingTeam = signingTeam
        self.admitsUnsignedHost = admitsUnsignedHost
        self.checkRunningCode = checkRunningCode
    }

    func verifiedExecutable(in bundle: Bundle) throws -> URL {
        let requirement = try requiredSignature()
        guard let executable = bundle.url(forAuxiliaryExecutable: Self.executableName) else {
            throw Self.untrusted("\(Self.executableName) is missing from \(bundle.bundleURL.lastPathComponent)")
        }
        try Self.verifyLocation(of: executable, inBundleAt: bundle.bundleURL)
        guard let requirement else { return executable }
        try Self.checkStaticCode(at: executable, requirement: requirement)
        return executable
    }

    func verifyRunningHelper(_ processIdentifier: pid_t) throws {
        guard let requirement = try requiredSignature() else { return }
        do {
            try checkRunningCode(processIdentifier, requirement)
        } catch let failure as HanaBridgeFailure {
            throw failure
        } catch {
            throw Self.untrusted("the running \(Self.executableName) failed its signature check: \(error.localizedDescription)")
        }
    }

    static func verifyLocation(of executable: URL, inBundleAt bundleURL: URL) throws {
        var status = stat()
        guard lstat(executable.path, &status) == 0 else {
            throw untrusted("\(executableName) could not be read")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw untrusted("\(executableName) is not a regular file")
        }
        guard access(executable.path, X_OK) == 0 else {
            throw untrusted("\(executableName) is not executable")
        }
        guard let resolvedExecutable = resolvedPath(executable.path),
              let resolvedBundle = resolvedPath(bundleURL.path),
              resolvedExecutable == resolvedBundle + "/Contents/MacOS/" + executableName
        else {
            throw untrusted("\(executableName) is not inside the plugin's Contents/MacOS folder")
        }
    }

    static func requirement(forTeam team: String) -> String? {
        let isTeamIdentifier = team.count == 10 && team.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard isTeamIdentifier else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func runningHostTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let requirementText = requirement(forTeam: team),
              let requirement = try? compiledRequirement(requirementText),
              SecCodeCheckValidity(code, dynamicValidationFlags, requirement) == errSecSuccess
        else { return nil }
        return team
    }

    static func checkRunningCode(processIdentifier: pid_t, requirement text: String) throws {
        let requirement = try compiledRequirement(text)
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            throw untrusted("the running \(executableName) could not be inspected (OSStatus \(guestStatus))")
        }
        let status = SecCodeCheckValidity(code, dynamicValidationFlags, requirement)
        guard status == errSecSuccess else {
            throw untrusted("the running \(executableName) does not satisfy \(text) (OSStatus \(status))")
        }
    }

    private func requiredSignature() throws -> String? {
        guard let signingTeam else {
            guard admitsUnsignedHost else {
                throw Self.untrusted(
                    "TablePro is not signed with a Team ID, so it cannot check the signature of \(Self.executableName)"
                )
            }
            return nil
        }
        guard let requirement = Self.requirement(forTeam: signingTeam) else {
            throw Self.untrusted("TablePro's signing Team ID is not valid")
        }
        return requirement
    }

    private static func checkStaticCode(at executable: URL, requirement text: String) throws {
        let requirement = try compiledRequirement(text)
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executable as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else {
            throw untrusted("\(executableName) could not be opened for signature checks (OSStatus \(createStatus))")
        }
        let status = SecStaticCodeCheckValidity(code, staticValidationFlags, requirement)
        guard status == errSecSuccess else {
            throw untrusted("\(executableName) does not satisfy \(text) (OSStatus \(status))")
        }
    }

    private static func compiledRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw untrusted("the signing requirement \(text) could not be built (OSStatus \(status))")
        }
        return requirement
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func untrusted(_ message: String) -> HanaBridgeFailure {
        HanaBridgeFailure(kind: .internalFailure, message: message)
    }
}
