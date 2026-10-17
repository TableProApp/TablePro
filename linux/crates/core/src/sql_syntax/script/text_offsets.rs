pub fn char_to_byte(text: &str, char_offset: usize) -> usize {
    text.char_indices()
        .nth(char_offset)
        .map_or(text.len(), |(byte, _)| byte)
}

/// How many chars start before `byte`.
pub fn byte_to_char(text: &str, byte: usize) -> usize {
    CharCounter::new(text).char_at(byte)
}

/// `byte_to_char` for offsets that only grow, such as a script's batch
/// starts. Each call counts only the text since the previous one, so a
/// whole script is one pass rather than one pass per batch.
#[derive(Debug)]
pub struct CharCounter<'a> {
    text: &'a str,
    byte: usize,
    chars: usize,
}

impl<'a> CharCounter<'a> {
    pub fn new(text: &'a str) -> Self {
        Self {
            text,
            byte: 0,
            chars: 0,
        }
    }

    /// An offset behind the previous one counts from the start again.
    pub fn char_at(&mut self, byte: usize) -> usize {
        let byte = byte.min(self.text.len());
        if byte < self.byte {
            self.byte = 0;
            self.chars = 0;
        }
        self.chars += self.text.as_bytes().get(self.byte..byte).map_or(0, char_starts);
        self.byte = byte;
        self.chars
    }
}

/// Every byte that is not a UTF-8 continuation byte starts a char.
fn char_starts(bytes: &[u8]) -> usize {
    bytes.iter().filter(|byte| **byte & 0xC0 != 0x80).count()
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    fn counted_from_the_start(text: &str, byte: usize) -> usize {
        text.char_indices().take_while(|(index, _)| *index < byte).count()
    }

    #[test]
    fn converts_ascii_offsets_one_to_one() {
        assert_eq!(char_to_byte("select", 3), 3);
        assert_eq!(byte_to_char("select", 3), 3);
    }

    #[test]
    fn clamps_past_the_end() {
        assert_eq!(char_to_byte("ab", 10), 2);
        assert_eq!(byte_to_char("ab", 10), 2);
    }

    #[test]
    fn an_offset_inside_a_char_counts_that_char() {
        // 'é' is bytes 1 and 2.
        assert_eq!(byte_to_char("aéb", 2), counted_from_the_start("aéb", 2));
        assert_eq!(byte_to_char("aéb", 2), 2);
    }

    proptest! {
        #[test]
        fn the_counter_agrees_with_counting_from_the_start(
            text in "[ -~\n\té😀]{0,80}",
            mut offsets in proptest::collection::vec(0usize..400, 0..12),
        ) {
            offsets.sort_unstable();
            let mut counter = CharCounter::new(&text);
            for offset in offsets.iter().copied().chain(offsets.iter().rev().copied()) {
                prop_assert_eq!(counter.char_at(offset), counted_from_the_start(&text, offset));
            }
        }
    }
}
