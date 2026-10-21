import Darwin
import Foundation
import TableProMCP
import TableProUtilities

@main
struct TableProCLI {
    static func main() async {
        let console = StandardConsole()
        let code = await CLIRunner.live(console: console).run(arguments: Array(CommandLine.arguments.dropFirst()))
        console.flush()
        // A full disk or a closed file must not pass for a complete export.
        if let failure = console.outputFailure, code == .success {
            console.err("tablepro: could not write the output: \(failure.localizedDescription)\n")
            exit(CLIExitCode.failure.rawValue)
        }
        exit(code.rawValue)
    }
}

private final class StandardConsole: CLIConsole, @unchecked Sendable {
    private static let flushThreshold = 64 * 1_024

    private let lock = NSLock()
    private var pending = Data()
    private var firstFailure: Error?

    var outputFailure: Error? {
        lock.withLock { firstFailure }
    }

    func out(_ text: String) {
        let ready: Data? = lock.withLock {
            pending.append(contentsOf: text.utf8)
            guard pending.count >= Self.flushThreshold else { return nil }
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        if let ready {
            writeOutput(ready)
        }
    }

    func err(_ text: String) {
        flush()
        Self.write(Data(text.utf8), to: STDERR_FILENO)
    }

    func flush() {
        let ready: Data = lock.withLock {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        guard !ready.isEmpty else { return }
        writeOutput(ready)
    }

    private func writeOutput(_ data: Data) {
        do {
            try DescriptorWrite.allBytes(data, to: STDOUT_FILENO)
        } catch {
            lock.withLock {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        try? DescriptorWrite.allBytes(data, to: descriptor)
    }
}
