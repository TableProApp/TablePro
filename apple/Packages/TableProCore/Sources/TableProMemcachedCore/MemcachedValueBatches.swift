public enum MemcachedValueBatches {
    static let maximumKeys = 1_000
    // Proxies buffer a request line whole, so a page of long keys goes out as several shorter lines.
    static let maximumLineBytes = 64 * 1_024
    // A request's timeout covers its whole reply, so a page of large items is read in parts.
    static let maximumListedBytes = 16 * 1_024 * 1_024

    private static let commandOverhead = "gets \r\n".utf8.count

    /// The keys of each `gets`, in listing order. A key over a limit by itself still goes out, alone.
    public static func split(_ entries: some Collection<MemcachedKeyEntry>) -> [[String]] {
        var batches: [[String]] = []
        var keys: [String] = []
        var lineBytes = commandOverhead
        var listedBytes = 0

        for entry in entries {
            let keyBytes = entry.key.utf8.count + 1
            // A listing is the server's word, so one absurd size cannot overflow the sum.
            let itemBytes = min(max(entry.size ?? 0, 0), MemcachedReplyReader.maximumValueLength)
            let isFull = keys.count >= maximumKeys
                || lineBytes + keyBytes > maximumLineBytes
                || listedBytes + itemBytes > maximumListedBytes
            if isFull, !keys.isEmpty {
                batches.append(keys)
                keys = []
                lineBytes = commandOverhead
                listedBytes = 0
            }
            keys.append(entry.key)
            lineBytes += keyBytes
            listedBytes += itemBytes
        }
        if !keys.isEmpty { batches.append(keys) }
        return batches
    }
}
