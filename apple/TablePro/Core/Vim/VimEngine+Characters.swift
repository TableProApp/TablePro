import Foundation

extension VimEngine {
    func characterStart(at offset: Int, in buffer: VimTextBuffer) -> Int {
        buffer.characterRange(at: offset).location
    }

    // At or past the end of the text this is the end of the text.
    func characterEnd(at offset: Int, in buffer: VimTextBuffer) -> Int {
        NSMaxRange(buffer.characterRange(at: offset))
    }

    // Stops at the last step that stays within `limit`; an offset already past it comes back to `limit`.
    func characterOffset(after offset: Int, count: Int, limit: Int, in buffer: VimTextBuffer) -> Int {
        var position = offset
        for _ in 0..<max(0, count) {
            let next = characterEnd(at: position, in: buffer)
            guard next > position, next <= limit else { break }
            position = next
        }
        return min(position, limit)
    }

    func characterOffset(before offset: Int, count: Int, limit: Int, in buffer: VimTextBuffer) -> Int {
        var position = offset
        for _ in 0..<max(0, count) {
            guard position > limit else { break }
            position = characterStart(at: position - 1, in: buffer)
        }
        return max(position, limit)
    }
}
