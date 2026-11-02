public enum WireLength {
    public static func checked(_ value: some BinaryInteger, limit: Int) throws(WireIOError) -> Int {
        guard let length = Int(exactly: value), length >= 0, length <= limit else {
            throw .lengthOutOfRange(String(value), limit: limit)
        }
        return length
    }
}
