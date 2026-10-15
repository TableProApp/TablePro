import Foundation

public enum BackgroundPipeReader {
    public static func everything(from reader: FileHandle, pausingFirst pause: TimeInterval) async -> Data? {
        await BoundedCall.resultOnItsOwnThread {
            Thread.sleep(forTimeInterval: pause)
            var bytes = Data()
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                bytes.append(chunk)
            }
            return bytes
        }
    }
}
