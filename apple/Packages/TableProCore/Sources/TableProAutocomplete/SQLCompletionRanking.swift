import Foundation

extension SQLCompletionProvider {
    // In emission order. The catalog's table list stays a segment of its own, so it is never copied or joined.
    enum CandidateSegment: Sendable {
        case items([SQLCompletionItem])
        case tables(SQLCompletionNameIndex)
    }

    // The order is the full sort's: score, then emission position. Only the best `pool` are kept, and an indexed
    // table becomes an item only once it is kept, so the cost is in the names that match, not in the catalog.
    @concurrent
    static func rankedSession(
        _ segments: [CandidateSegment],
        context: SQLContext,
        limit: Int,
        pool: Int
    ) async -> SQLCompletionSession {
        let prefix = context.prefix
        let lowerPrefix = prefix.lowercased()
        var selection = RankedSelection(capacity: pool)
        var items: [SQLCompletionItem] = []
        var indexes: [(index: SQLCompletionNameIndex, base: Int)] = []
        var matched = 0
        var position = 0

        // Positions run over the segment as emitted, so a survivor keeps its place relative to every other one.
        func rank(_ segment: [SQLCompletionItem], base: Int) {
            let named = context.quotedName == nil ? segment : segment.filter { nameKinds.contains($0.kind) }
            let survivors = prefix.isEmpty ? named : filterByPrefix(named, prefix: prefix)
            matched += survivors.count
            for (offset, candidate) in survivors.enumerated() {
                let key = RankedSelection.key(
                    score: calculateScore(for: candidate, prefix: lowerPrefix, context: context),
                    position: base + offset
                )
                if selection.admits(key) {
                    selection.insert(key: key, reference: items.count)
                    items.append(candidate)
                }
            }
        }

        let typed = SQLCompletionNameIndex.simpleKey(lowerPrefix)
        for segment in segments {
            switch segment {
            case .items(let segmentItems):
                rank(segmentItems, base: position)
                position += segmentItems.count
            case .tables(let index):
                if typed != nil {
                    indexes.append((index, position))
                } else {
                    rank((0..<index.count).map(index.item(at:)), base: position)
                }
                position += index.count
            }
        }

        guard let typed else {
            return session(selection: selection, items: items, indexes: [], matched: matched, limit: limit, pool: pool,
                           prefix: prefix, context: context)
        }

        // Every name another matcher reads goes through the provider's own, so it ranks exactly as an item would.
        for (slot, entry) in indexes.enumerated() {
            let index = entry.index
            // Each complex row ranks at its own list position, never at one the batch would give it.
            for row in index.complexRows {
                rank([index.item(at: Int(row))], base: entry.base + Int(row))
            }

            let range = index.prefixRange(typed)
            matched += range.count
            for sortedSlot in range {
                let row = Int(index.sortedRows[sortedSlot])
                let length = Int(index.starts[row + 1] - index.starts[row])
                let kind: SQLCompletionKind = index.isView[row] ? .view : .table
                let key = RankedSelection.key(
                    score: score(
                        kind: kind,
                        priority: kind.basePriority,
                        startsWithPrefix: true,
                        equalsPrefix: length == typed.count,
                        labelLength: length,
                        prefixIsEmpty: typed.isEmpty,
                        context: context
                    ),
                    position: entry.base + row
                )
                if selection.admits(key) {
                    selection.insert(key: key, reference: RankedSelection.indexReference(slot: slot, row: row))
                }
            }
        }

        // A name that contains the prefix, or holds it as a subsequence, is longer than it and gets no prefix bonus.
        // Once the kept pool all scores below the best such a name could, the passes that find them are skipped.
        let bestOtherScore = [SQLCompletionKind.table, .view].map { kind in
            score(
                kind: kind,
                priority: kind.basePriority,
                startsWithPrefix: false,
                equalsPrefix: false,
                labelLength: typed.count + 1,
                prefixIsEmpty: false,
                context: context
            )
        }.min() ?? 0
        let poolIsSettled = matched > pool
            && selection.worstKey.map { $0 < RankedSelection.key(score: bestOtherScore, position: 0) } == true
        if !typed.isEmpty, !poolIsSettled {
            for (slot, entry) in indexes.enumerated() {
                matched += rankNonPrefixRows(
                    of: entry.index, slot: slot, base: entry.base, typed: typed, context: context, into: &selection
                )
            }
        }

        return session(selection: selection, items: items, indexes: indexes.map(\.index), matched: matched,
                       limit: limit, pool: pool, prefix: prefix, context: context)
    }

    private static func rankNonPrefixRows(
        of index: SQLCompletionNameIndex,
        slot: Int,
        base: Int,
        typed: [UInt16],
        context: SQLContext,
        into selection: inout RankedSelection
    ) -> Int {
        var matched = 0
        index.units.withUnsafeBufferPointer { keys in
            typed.withUnsafeBufferPointer { pattern in
                for row in 0..<index.count where index.isSimple[row] {
                    let start = Int(index.starts[row])
                    let end = Int(index.starts[row + 1])
                    let target = UnsafeBufferPointer(rebasing: keys[start..<end])
                    guard !startsWith(target, pattern) else { continue }
                    let penalty: Int
                    if contains(target, pattern) {
                        penalty = 0
                    } else if let fuzzy = subsequencePenalty(of: pattern, in: target) {
                        penalty = fuzzy
                    } else {
                        continue
                    }
                    matched += 1
                    let kind: SQLCompletionKind = index.isView[row] ? .view : .table
                    let key = RankedSelection.key(
                        score: score(
                            kind: kind,
                            priority: kind.basePriority + penalty,
                            startsWithPrefix: false,
                            equalsPrefix: false,
                            labelLength: end - start,
                            prefixIsEmpty: false,
                            context: context
                        ),
                        position: base + row
                    )
                    if selection.admits(key) {
                        selection.insert(key: key, reference: RankedSelection.indexReference(slot: slot, row: row))
                    }
                }
            }
        }
        return matched
    }

    private static func session(
        selection: RankedSelection,
        items: [SQLCompletionItem],
        indexes: [SQLCompletionNameIndex],
        matched: Int,
        limit: Int,
        pool: Int,
        prefix: String,
        context: SQLContext
    ) -> SQLCompletionSession {
        let candidates = selection.ascending().map { reference -> SQLCompletionItem in
            guard let (slot, row) = RankedSelection.indexRow(of: reference) else { return items[reference] }
            let item = indexes[slot].item(at: row)
            // The ranges come from the same matcher an item takes, for the few names kept.
            return prefix.isEmpty ? item : filterByPrefix([item], prefix: prefix).first ?? item
        }
        return SQLCompletionSession(
            items: Array(candidates.prefix(limit)),
            candidates: candidates,
            context: context,
            candidatesTruncated: matched > pool
        )
    }

    private static func startsWith(_ target: UnsafeBufferPointer<UInt16>, _ pattern: UnsafeBufferPointer<UInt16>) -> Bool {
        guard target.count >= pattern.count else { return false }
        for offset in 0..<pattern.count where target[offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func contains(_ target: UnsafeBufferPointer<UInt16>, _ pattern: UnsafeBufferPointer<UInt16>) -> Bool {
        let last = target.count - pattern.count
        guard last >= 0, let first = pattern.first else { return false }
        var start = 0
        while start <= last {
            if target[start] == first {
                var offset = 1
                while offset < pattern.count, target[start + offset] == pattern[offset] {
                    offset += 1
                }
                if offset == pattern.count { return true }
            }
            start += 1
        }
        return false
    }

    // The penalty `resolveFuzzyMatch` gives, over the same units.
    private static func subsequencePenalty(of pattern: UnsafeBufferPointer<UInt16>, in target: UnsafeBufferPointer<UInt16>) -> Int? {
        guard !pattern.isEmpty, !target.isEmpty else { return nil }
        var patternIndex = 0
        var gaps = 0
        var consecutive = 0
        var maxConsecutive = 0
        var lastMatch = -1
        for targetIndex in 0..<target.count where patternIndex < pattern.count {
            guard pattern[patternIndex] == target[targetIndex] else { continue }
            if lastMatch == targetIndex - 1 {
                consecutive += 1
                maxConsecutive = max(maxConsecutive, consecutive)
            } else {
                if lastMatch >= 0 {
                    gaps += targetIndex - lastMatch - 1
                }
                consecutive = 1
            }
            lastMatch = targetIndex
            patternIndex += 1
        }
        guard patternIndex == pattern.count else { return nil }
        return max(0, 50 + gaps * 10 - maxConsecutive * 15)
    }
}

// The best `capacity` keys seen, as a max-heap so the worst kept one is replaced in log time.
struct RankedSelection {
    private(set) var keys: [Int64] = []
    private var references: [Int] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 0)
        keys.reserveCapacity(self.capacity)
        references.reserveCapacity(self.capacity)
    }

    // Score first, then emission position, as the full sort ordered them; positions are unique, so keys are too.
    static func key(score: Int, position: Int) -> Int64 {
        Int64(score) * (1 << 32) + Int64(position)
    }

    // An indexed row is a negative reference, so an item's index into the kept items stays as it is.
    static func indexReference(slot: Int, row: Int) -> Int {
        -1 - (slot << 32 | row)
    }

    static func indexRow(of reference: Int) -> (slot: Int, row: Int)? {
        guard reference < 0 else { return nil }
        let packed = -1 - reference
        return (packed >> 32, packed & 0xFFFF_FFFF)
    }

    var worstKey: Int64? {
        keys.count == capacity ? keys.first : nil
    }

    func admits(_ key: Int64) -> Bool {
        capacity > 0 && (keys.count < capacity || key < keys[0])
    }

    mutating func insert(key: Int64, reference: Int) {
        if keys.count < capacity {
            keys.append(key)
            references.append(reference)
            siftUp(keys.count - 1)
        } else {
            keys[0] = key
            references[0] = reference
            siftDown(0)
        }
    }

    func ascending() -> [Int] {
        keys.indices.sorted { keys[$0] < keys[$1] }.map { references[$0] }
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard keys[child] > keys[parent] else { return }
            keys.swapAt(child, parent)
            references.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var largest = parent
            if left < keys.count, keys[left] > keys[largest] { largest = left }
            if right < keys.count, keys[right] > keys[largest] { largest = right }
            guard largest != parent else { return }
            keys.swapAt(parent, largest)
            references.swapAt(parent, largest)
            parent = largest
        }
    }
}
