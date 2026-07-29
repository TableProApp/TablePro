import Foundation

struct BigUInt: Equatable, CustomStringConvertible {
    private(set) var limbs: [UInt32]

    init() { limbs = [] }

    init(_ value: UInt32) { limbs = value == 0 ? [] : [value] }

    init(limbs: [UInt32]) {
        var normalized = limbs
        while normalized.last == 0 { normalized.removeLast() }
        self.limbs = normalized
    }

    init(bytesBE bytes: [UInt8]) {
        var built: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            var limb: UInt32 = 0
            var shift: UInt32 = 0
            var taken = 0
            while taken < 4 && index > 0 {
                index -= 1
                limb |= UInt32(bytes[index]) << shift
                shift += 8
                taken += 1
            }
            built.append(limb)
        }
        self.init(limbs: built)
    }

    init?(hex: String) {
        var trimmed = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if trimmed.count % 2 == 1 { trimmed = "0" + trimmed }
        var bytes: [UInt8] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            let next = trimmed.index(cursor, offsetBy: 2)
            guard let byte = UInt8(trimmed[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        self.init(bytesBE: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var byteCount: Int {
        guard let top = limbs.last else { return 0 }
        let topBytes: Int
        switch top {
        case 0...0xFF: topBytes = 1
        case 0x100...0xFFFF: topBytes = 2
        case 0x10000...0xFFFFFF: topBytes = 3
        default: topBytes = 4
        }
        return (limbs.count - 1) * 4 + topBytes
    }

    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bytesBE(minCount: Int = 0) -> [UInt8] {
        let count = max(byteCount, minCount)
        guard count > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(count)
        for byteIndex in stride(from: count - 1, through: 0, by: -1) {
            let limbIndex = byteIndex / 4
            let shift = UInt32((byteIndex % 4) * 8)
            let limb = limbIndex < limbs.count ? limbs[limbIndex] : 0
            out.append(UInt8((limb >> shift) & 0xFF))
        }
        return out
    }

    func bit(_ position: Int) -> Bool {
        let limbIndex = position / 32
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> UInt32(position % 32)) & 1 == 1
    }

    var description: String {
        isZero ? "0" : bytesBE().map { String(format: "%02x", $0) }.joined()
    }

    static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        let count = max(lhs.count, rhs.count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            let left = i < lhs.count ? lhs[i] : 0
            let right = i < rhs.count ? rhs[i] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    func shiftedLeftOneBit() -> BigUInt {
        var out = [UInt32]()
        out.reserveCapacity(limbs.count + 1)
        var carry: UInt32 = 0
        for limb in limbs {
            out.append((limb << 1) | carry)
            carry = limb >> 31
        }
        if carry != 0 { out.append(carry) }
        return BigUInt(limbs: out)
    }

    func settingLowBit() -> BigUInt {
        var out = limbs
        if out.isEmpty { out = [1] } else { out[0] |= 1 }
        return BigUInt(limbs: out)
    }

    func subtracting(_ other: BigUInt) -> BigUInt {
        var out = [UInt32]()
        out.reserveCapacity(limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<limbs.count {
            let a = UInt64(limbs[i])
            let b = (i < other.limbs.count ? UInt64(other.limbs[i]) : 0) + borrow
            if a >= b {
                out.append(UInt32(a - b))
                borrow = 0
            } else {
                out.append(UInt32(a + 0x1_0000_0000 - b))
                borrow = 1
            }
        }
        return BigUInt(limbs: out)
    }

    func mod(_ modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "modulo by zero")
        var remainder = BigUInt()
        for position in stride(from: bitLength - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeftOneBit()
            if bit(position) { remainder = remainder.settingLowBit() }
            if BigUInt.compare(remainder.limbs, modulus.limbs) >= 0 {
                remainder = remainder.subtracting(modulus)
            }
        }
        return remainder
    }

    func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "modulo by zero")
        if modulus.limbs == [1] { return BigUInt() }
        precondition(modulus.limbs[0] & 1 == 1, "Montgomery modPow requires an odd modulus")
        if exponent.isZero { return BigUInt(1).mod(modulus) }

        let size = modulus.limbs.count
        let n = BigUInt.padded(modulus.limbs, to: size)
        let nInv = BigUInt.montgomeryInverse(n[0])

        let rSquaredLimbs = [UInt32](repeating: 0, count: 2 * size) + [1]
        let rSquared = BigUInt.padded(BigUInt(limbs: rSquaredLimbs).mod(modulus).limbs, to: size)

        let baseMont = BigUInt.montgomeryMultiply(
            BigUInt.padded(mod(modulus).limbs, to: size), rSquared, n, nInv, size)
        var accumulator = BigUInt.montgomeryMultiply(
            BigUInt.padded([1], to: size), rSquared, n, nInv, size)

        for position in stride(from: exponent.bitLength - 1, through: 0, by: -1) {
            accumulator = BigUInt.montgomeryMultiply(accumulator, accumulator, n, nInv, size)
            if exponent.bit(position) {
                accumulator = BigUInt.montgomeryMultiply(accumulator, baseMont, n, nInv, size)
            }
        }

        let result = BigUInt.montgomeryMultiply(
            accumulator, BigUInt.padded([1], to: size), n, nInv, size)
        return BigUInt(limbs: result)
    }

    private static func padded(_ limbs: [UInt32], to size: Int) -> [UInt32] {
        if limbs.count >= size { return Array(limbs[0..<size]) }
        return limbs + [UInt32](repeating: 0, count: size - limbs.count)
    }

    private static func montgomeryInverse(_ n0: UInt32) -> UInt32 {
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- n0 &* inverse) }
        return 0 &- inverse
    }

    private static func montgomeryMultiply(
        _ a: [UInt32], _ b: [UInt32], _ n: [UInt32], _ nInv: UInt32, _ size: Int
    ) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: size + 2)
        for i in 0..<size {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<size {
                let product = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                t[j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            let sum = UInt64(t[size]) + carry
            t[size] = UInt32(truncatingIfNeeded: sum)
            t[size + 1] = UInt32(sum >> 32)

            let m = UInt64(UInt32(truncatingIfNeeded: UInt64(t[0]) &* UInt64(nInv)))
            var reduceCarry = (UInt64(t[0]) + m * UInt64(n[0])) >> 32
            for j in 1..<size {
                let product = UInt64(t[j]) + m * UInt64(n[j]) + reduceCarry
                t[j - 1] = UInt32(truncatingIfNeeded: product)
                reduceCarry = product >> 32
            }
            let tail = UInt64(t[size]) + reduceCarry
            t[size - 1] = UInt32(truncatingIfNeeded: tail)
            t[size] = t[size + 1] &+ UInt32(tail >> 32)
        }

        var result = Array(t[0..<size])
        if t[size] != 0 || BigUInt.compare(result, n) >= 0 {
            var borrow: UInt64 = 0
            for j in 0..<size {
                let a = UInt64(result[j])
                let b = UInt64(n[j]) + borrow
                if a >= b {
                    result[j] = UInt32(a - b)
                    borrow = 0
                } else {
                    result[j] = UInt32(a + 0x1_0000_0000 - b)
                    borrow = 1
                }
            }
        }
        return result
    }
}
