import Foundation

// hiredis reads each argument by the length passed beside it, so a NUL or a non-UTF-8 byte stays in the argument.
public enum RedisCommandArgv {
    public static func withPointers<T>(
        _ arguments: [Data],
        body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, UnsafeMutablePointer<Int>) throws -> T
    ) rethrows -> T {
        let buffers: [UnsafeMutablePointer<CChar>] = arguments.map { argument in
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: argument.count + 1)
            argument.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: CChar.self).baseAddress {
                    buffer.initialize(from: base, count: argument.count)
                }
            }
            buffer[argument.count] = 0
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }

        let argv = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(arguments.count, 1))
        let argvlen = UnsafeMutablePointer<Int>.allocate(capacity: max(arguments.count, 1))
        defer {
            argv.deallocate()
            argvlen.deallocate()
        }

        for index in arguments.indices {
            argv[index] = UnsafePointer(buffers[index])
            argvlen[index] = arguments[index].count
        }

        return try body(argv, argvlen)
    }
}
