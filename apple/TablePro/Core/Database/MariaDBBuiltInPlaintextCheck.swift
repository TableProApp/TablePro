//
//  MariaDBBuiltInPlaintextCheck.swift
//  TablePro
//

import Darwin
import Foundation
import os
import TableProUtilities

// A MariaDB client built with mysql_clear_password or dialog inside it finds them before it looks at the plugin folder,
// so the private folder cannot hold them back. Asking the tool itself, with an empty folder, against a loopback server
// that wants each of them in turn holds for every build. Homebrew's tools load both from the folder and pass.
enum MariaDBBuiltInPlaintextCheck {
    enum Verdict: Equatable, Sendable {
        case refusesPlaintext
        case sendsPlaintext
        // The tool never showed either: it did not run, connect or answer in time.
        case unknown
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MariaDBBuiltInPlaintextCheck")
    private static let plugins = ["mysql_clear_password", "dialog"]
    private static let verdicts = OSAllocatedUnfairLock<[String: Verdict]>(initialState: [:])

    // Only an answer the tool gave is kept, so an unknown one is asked again next time.
    static func verdict(toolPath: String, timeout: Int32 = 10) async -> Verdict {
        let key = cacheKey(toolPath)
        if let key, let known = verdicts.withLock({ $0[key] }) {
            return known
        }
        let verdict = await Task.detached(priority: .userInitiated) {
            var combined = Verdict.refusesPlaintext
            for plugin in Self.plugins {
                switch Self.ask(toolPath: toolPath, plugin: plugin, timeout: timeout) {
                case .sendsPlaintext: return Verdict.sendsPlaintext
                case .unknown: combined = .unknown
                case .refusesPlaintext: break
                }
            }
            return combined
        }.value
        if let key, verdict != .unknown {
            verdicts.withLock { $0[key] = verdict }
        }
        return verdict
    }

    private static func cacheKey(_ toolPath: String) -> String? {
        let resolved = URL(fileURLWithPath: toolPath).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return "\(resolved)|\(modified.timeIntervalSince1970)|\(size)"
    }

    private static func ask(toolPath: String, plugin: String, timeout: Int32) -> Verdict {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("tablepro-plugin-check-\(UUID().uuidString)")
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else { return .unknown }
        defer { try? manager.removeItem(at: folder) }
        guard let listener = PluginCheckListener() else { return .unknown }
        defer { close(listener.descriptor) }

        let token = "tablepro-check-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [
            "--no-defaults", "--protocol=TCP", "-h", "127.0.0.1", "-P", String(listener.port), "-u", "tablepro",
            "--skip-ssl", "--plugin-dir=\(folder.path)", "--", "tablepro"
        ]
        process.environment = ["MYSQL_PWD": token]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.notice("Could not run the client to check its plugins: \(error.publicLogShape, privacy: .public)")
            return .unknown
        }
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        guard let client = listener.accept(within: timeout) else { return .unknown }
        defer { close(client) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        guard send(packet: greeting, sequence: 0, to: client),
              case .packet(let login, _) = receivePacket(from: client)
        else { return .unknown }
        var request = [0xFE] + Array(plugin.utf8) + [0]
        if plugin == "dialog" {
            request += [0x05] + Array("Password: ".utf8)
        }
        guard send(packet: request, sequence: login &+ 1, to: client) else { return .unknown }
        switch receivePacket(from: client) {
        case .packet(_, let answer) where contains(answer, Array(token.utf8)):
            logger.error("\(toolPath, privacy: .private(mask: .hash)) sends the password for \(plugin, privacy: .public) without TLS")
            return .sendsPlaintext
        case .packet, .closed:
            return .refusesPlaintext
        case .silent:
            return .unknown
        }
    }

    private static let greeting: [UInt8] = {
        let capabilities: UInt32 = 0x1 | 0x8 | 0x200 | 0x2000 | 0x8000 | 0x20000 | 0x80000
        var payload: [UInt8] = [10] + Array("8.0.36".utf8) + [0]
        payload += [1, 0, 0, 0] + Array("abcdefgh".utf8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8((capabilities >> 8) & 0xFF), 45, 2, 0]
        payload += [UInt8((capabilities >> 16) & 0xFF), UInt8((capabilities >> 24) & 0xFF), 21]
        payload += [UInt8](repeating: 0, count: 10)
        payload += Array("ijklmnopqrst".utf8) + [0] + Array("mysql_native_password".utf8) + [0]
        return payload
    }()

    private enum Received {
        case packet(sequence: UInt8, payload: [UInt8])
        case closed
        case silent
    }

    private static func send(packet payload: [UInt8], sequence: UInt8, to descriptor: Int32) -> Bool {
        let length = payload.count
        let bytes = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), sequence] + payload
        return bytes.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0) == buffer.count
        }
    }

    private static func receivePacket(from descriptor: Int32) -> Received {
        let header: [UInt8]
        switch receive(4, from: descriptor) {
        case .packet(_, let bytes): header = bytes
        case let other: return other
        }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
        guard length > 0 else { return .packet(sequence: header[3], payload: []) }
        switch receive(length, from: descriptor) {
        case .packet(_, let payload): return .packet(sequence: header[3], payload: payload)
        case let other: return other
        }
    }

    private static func receive(_ count: Int, from descriptor: Int32) -> Received {
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = bytes.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress?.advanced(by: filled), count - filled, 0)
            }
            if read > 0 {
                filled += read
            } else if read == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                return .closed
            } else {
                return .silent
            }
        }
        return .packet(sequence: 0, payload: bytes)
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

private struct PluginCheckListener {
    let descriptor: Int32
    let port: Int

    init?() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && listen(descriptor, 1) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func accept(within seconds: Int32) -> Int32? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, seconds * 1_000) == 1 else { return nil }
        let client = Darwin.accept(descriptor, nil, nil)
        return client >= 0 ? client : nil
    }
}
