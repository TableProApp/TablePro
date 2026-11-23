//
//  ConnectionEditorStore+Cloudflare.swift
//  TablePro
//

import Foundation
import os
import TableProProcess

// Runs `cloudflared access login` for the editor and reports how it ended.
@MainActor
final class CloudflareAccessLogin {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareAccessLogin")

    private var process: Process?

    var isRunning: Bool { process?.isRunning == true }

    func start(binaryPath: String, hostname: String, onFinish: @escaping @MainActor (String?) -> Void) -> String? {
        let launched: Process
        do {
            launched = try ProcessLauncher.process(for: ProcessCommand(
                executable: URL(fileURLWithPath: binaryPath),
                arguments: ["access", "login", hostname],
                environment: ProcessEnvironment.inherited()
            ))
        } catch {
            return error.localizedDescription
        }
        // Reap the child and surface a failed login, which otherwise left no feedback.
        launched.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.process = nil
                guard status != 0 else {
                    onFinish(nil)
                    return
                }
                Self.logger.error("cloudflared access login exited \(status, privacy: .public)")
                onFinish(String(
                    localized: "cloudflared sign-in did not complete. Check the hostname and your Cloudflare Access app, then try again."
                ))
            }
        }
        do {
            try launched.run()
            process = launched
            Self.logger.info("Started cloudflared access login for \(hostname, privacy: .private(mask: .hash))")
            return nil
        } catch {
            Self.logger.error("cloudflared access login failed to start: \(error.publicLogShape, privacy: .public)")
            return error.localizedDescription
        }
    }
}

extension ConnectionEditorStore {
    var cloudflaredPath: String? {
        let typed = draft.cloudflare.binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return (typed as NSString).expandingTildeInPath }
        if case .found(let path) = cloudflaredDetection { return path }
        return nil
    }

    func signInWithCloudflare() {
        cloudflareSignInError = nil
        let login = cloudflareLogin ?? CloudflareAccessLogin()
        cloudflareLogin = login
        guard !login.isRunning else { return }

        let hostname = draft.cloudflare.accessHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return }
        // A bare operand: cloudflared would read a dash-led hostname as an option.
        let refused = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !hostname.hasPrefix("-"), !hostname.unicodeScalars.contains(where: { refused.contains($0) }) else {
            cloudflareSignInError = String(
                localized: "The Cloudflare hostname cannot start with a dash or contain spaces or control characters."
            )
            return
        }
        guard let path = cloudflaredPath, FileManager.default.isExecutableFile(atPath: path) else {
            cloudflareSignInError = String(localized: "cloudflared was not found. Set its path below first.")
            return
        }
        isCloudflareSignInRunning = true
        if let failure = login.start(binaryPath: path, hostname: hostname, onFinish: { [weak self] error in
            self?.isCloudflareSignInRunning = false
            self?.cloudflareSignInError = error
        }) {
            isCloudflareSignInRunning = false
            cloudflareSignInError = failure
        }
    }
}
