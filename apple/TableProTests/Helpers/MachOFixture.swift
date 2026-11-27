import Foundation
@testable import TablePro

// Enough of a Mach-O for CoreFoundation to read its architectures; nothing can load it.
enum MachOFixture {
    static let arm64 = NSBundleExecutableArchitectureARM64
    static let x86_64 = NSBundleExecutableArchitectureX86_64

    static var otherArchitecture: Int {
        PluginManager.runningArchitecture == arm64 ? x86_64 : arm64
    }

    static func thin(_ architecture: Int) -> Data {
        var data = Data()
        // mach_header_64: magic, cputype, cpusubtype, MH_BUNDLE, no load commands.
        for field: UInt32 in [0xFEED_FACF, UInt32(architecture), 0, 8, 0, 0, 0, 0] {
            withUnsafeBytes(of: field.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fat(_ architectures: [Int]) -> Data {
        let sliceAlignment = 4_096
        var data = Data()
        func appendBigEndian(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        appendBigEndian(0xCAFE_BABE)
        appendBigEndian(UInt32(architectures.count))
        for (index, architecture) in architectures.enumerated() {
            appendBigEndian(UInt32(architecture))
            appendBigEndian(0)
            appendBigEndian(UInt32(sliceAlignment * (index + 1)))
            appendBigEndian(UInt32(thin(architecture).count))
            appendBigEndian(12)
        }
        for (index, architecture) in architectures.enumerated() {
            data.append(Data(count: sliceAlignment * (index + 1) - data.count))
            data.append(thin(architecture))
        }
        return data
    }

    // Writes the executable the bundle's Info.plist names under CFBundleExecutable.
    static func writeExecutable(_ executable: Data, named name: String, into bundleURL: URL) throws {
        let macOS = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try executable.write(to: macOS.appendingPathComponent(name, isDirectory: false))
    }
}
