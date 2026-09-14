pub fn char_to_byte(text: &str, char_offset: usize) -> usize {
    text.char_indices()
        .nth(char_offset)
        .map_or(text.len(), |(byte, _)| byte)
}

pub fn byte_to_char(text: &str, byte: usize) -> usize {
    text.char_indices().take_while(|(index, _)| *index < byte).count()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
