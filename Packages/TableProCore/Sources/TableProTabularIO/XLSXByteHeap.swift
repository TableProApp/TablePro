import Foundation

final class XLSXByteHeap: @unchecked Sendable {
    static let empty = XLSXByteHeap(blocks: [])

    private let blocks: [UnsafeMutableRawBufferPointer]

    fileprivate init(blocks: [UnsafeMutableRawBufferPointer]) {
        self.blocks = blocks
    }

    deinit {
        for block in blocks {
            block.deallocate()
        }
    }

    func bytes(at handle: UInt64) -> UnsafeBufferPointer<UInt8> {
        let blockIndex = Int(handle >> 32)
        let offset = Int(handle & 0xFFFF_FFFF)
        guard blockIndex < blocks.count, let base = blocks[blockIndex].baseAddress else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        let length = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        let start = (base + offset + 4).assumingMemoryBound(to: UInt8.self)
        return UnsafeBufferPointer(start: start, count: length)
    }
}

final class XLSXByteHeapBuilder {
    private static let blockSize = 1 << 20
    private static let prefixLength = 4

    private var blocks: [UnsafeMutableRawBufferPointer] = []
    private var used = 0

    deinit {
        for block in blocks {
            block.deallocate()
        }
    }

    func append(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        let length = min(bytes.count, Int(UInt32.max) - Self.prefixLength)
        let needed = length + Self.prefixLength
        if blocks.isEmpty || used + needed > blocks[blocks.count - 1].count {
            let block = UnsafeMutableRawBufferPointer.allocate(byteCount: max(Self.blockSize, needed), alignment: 8)
            blocks.append(block)
            used = 0
        }
        let blockIndex = blocks.count - 1
        guard let base = blocks[blockIndex].baseAddress else { return 0 }
        let offset = used
        base.storeBytes(of: UInt32(length), toByteOffset: offset, as: UInt32.self)
        if let source = bytes.baseAddress, length > 0 {
            (base + offset + Self.prefixLength).copyMemory(from: source, byteCount: length)
        }
        used += needed
        return UInt64(blockIndex) << 32 | UInt64(offset)
    }

    func finish() -> XLSXByteHeap {
        let heap = XLSXByteHeap(blocks: blocks)
        blocks = []
        used = 0
        return heap
    }
}
