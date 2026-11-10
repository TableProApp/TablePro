use std::borrow::Cow;
use std::ops::Range;

// The macOS app's cap per line: past it a value of control bytes would draw one mark each.
pub const MAX_MARKS: usize = 4_096;

const EMOJI_TAG_BASE: u32 = 0x1F3F4;

const C0_LABELS: [&str; 32] = [
    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI", "DLE",
    "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
];

const C1_LABELS: [&str; 32] = [
    "PAD", "HOP", "BPH", "NBH", "IND", "NEL", "SSA", "ESA", "HTS", "HTJ", "VTS", "PLD", "PLU", "RI", "SS2", "SS3",
    "DCS", "PU1", "PU2", "STS", "CCH", "MW", "SPA", "EPA", "SOS", "SGC", "SCI", "CSI", "ST", "OSC", "PM", "APC",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpecialCharacter {
    /// Drawn as its short name, since it has no width or no glyph of its own.
    Marker(Cow<'static, str>),
    /// A space other than U+0020, drawn at its own width.
    BlankSpace,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classified {
    /// Bytes of the text the character takes.
    pub range: Range<usize>,
    pub character: SpecialCharacter,
}

/// The zero-width, control and special space characters of `text`, as the
/// macOS app's "Show invisible characters" marks them. `line_breaks` is for
/// a one-line view, which draws no break for LF or CR.
pub fn special_characters(text: &str, line_breaks: bool) -> SpecialCharacters<'_> {
    SpecialCharacters {
        text,
        chars: text.char_indices(),
        line_breaks,
        tag_sequence: false,
        found: 0,
    }
}

pub struct SpecialCharacters<'a> {
    text: &'a str,
    chars: std::str::CharIndices<'a>,
    line_breaks: bool,
    // Whether the characters so far end in an emoji tag sequence's base and tags.
    tag_sequence: bool,
    found: usize,
}

impl Iterator for SpecialCharacters<'_> {
    type Item = Classified;

    fn next(&mut self) -> Option<Classified> {
        while self.found < MAX_MARKS {
            let (index, character) = self.chars.next()?;
            let in_tag_sequence = self.tag_sequence;
            let value = u32::from(character);
            self.tag_sequence = value == EMOJI_TAG_BASE || (is_tag(value) && in_tag_sequence);
            let end = index + character.len_utf8();
            let Some(kind) = self.classify(value, index..end, in_tag_sequence) else {
                continue;
            };
            self.found += 1;
            return Some(Classified {
                range: index..end,
                character: kind,
            });
        }
        None
    }
}

impl SpecialCharacters<'_> {
    fn classify(&self, value: u32, range: Range<usize>, in_tag_sequence: bool) -> Option<SpecialCharacter> {
        let marker = |label| Some(SpecialCharacter::Marker(label));
        match value {
            0x0A | 0x0D if self.line_breaks => marker(control_label(value)),
            0x09 | 0x0A | 0x0D => None,
            0x00..=0x1F | 0x7F..=0x9F => marker(control_label(value)),
            0x2028 | 0x2029 | 0xFFF9..=0xFFFB => marker(label(value)),
            0x00A0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000 => Some(SpecialCharacter::BlankSpace),
            _ if is_default_ignorable(value) && !self.is_exempt(value, range, in_tag_sequence) => marker(label(value)),
            _ => None,
        }
    }

    // Each of these shapes the characters around it, as a joiner inside an
    // emoji or a variation selector does, so marking it would break what the
    // reader sees.
    fn is_exempt(&self, value: u32, range: Range<usize>, in_tag_sequence: bool) -> bool {
        match value {
            0x034F | 0x115F | 0x1160 | 0x17B4 | 0x17B5 | 0x180B..=0x180D | 0x180F => true,
            0xFE00..=0xFE0F | 0xE0100..=0xE01EF => true,
            0x200C | 0x200D => self.joins_non_ascii(range),
            _ if is_tag(value) => in_tag_sequence,
            _ => false,
        }
    }

    fn joins_non_ascii(&self, range: Range<usize>) -> bool {
        let before = self.text[..range.start].chars().next_back();
        let after = self.text[range.end..].chars().next();
        before.into_iter().chain(after).any(|neighbour| !neighbour.is_ascii())
    }
}

fn is_tag(value: u32) -> bool {
    (0xE0020..=0xE007F).contains(&value)
}

fn is_default_ignorable(value: u32) -> bool {
    matches!(
        value,
        0x00AD
            | 0x034F
            | 0x061C
            | 0x115F..=0x1160
            | 0x17B4..=0x17B5
            | 0x180B..=0x180F
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x206F
            | 0x3164
            | 0xFE00..=0xFE0F
            | 0xFEFF
            | 0xFFA0
            | 0xFFF0..=0xFFF8
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0000..=0xE0FFF
    )
}

fn control_label(value: u32) -> Cow<'static, str> {
    let named = match value {
        0x00..=0x1F => usize::try_from(value).ok().and_then(|index| C0_LABELS.get(index)),
        0x7F => Some(&"DEL"),
        0x80..=0x9F => usize::try_from(value - 0x80)
            .ok()
            .and_then(|index| C1_LABELS.get(index)),
        _ => None,
    };
    named.map_or_else(|| hex_label(value), |label| Cow::Borrowed(*label))
}

fn label(value: u32) -> Cow<'static, str> {
    let named = match value {
        0x00AD => "SHY",
        0x061C => "ALM",
        0x180E => "MVS",
        0x200B => "ZWSP",
        0x200C => "ZWNJ",
        0x200D => "ZWJ",
        0x200E => "LRM",
        0x200F => "RLM",
        0x2028 => "LSEP",
        0x2029 => "PSEP",
        0x202A => "LRE",
        0x202B => "RLE",
        0x202C => "PDF",
        0x202D => "LRO",
        0x202E => "RLO",
        0x2060 => "WJ",
        0x2066 => "LRI",
        0x2067 => "RLI",
        0x2068 => "FSI",
        0x2069 => "PDI",
        0x206A => "ISS",
        0x206B => "ASS",
        0x206C => "IAFS",
        0x206D => "AAFS",
        0x206E => "NADS",
        0x206F => "NODS",
        0xFEFF => "BOM",
        0xFFF9 => "IAA",
        0xFFFA => "IAS",
        0xFFFB => "IAT",
        _ => return hex_label(value),
    };
    Cow::Borrowed(named)
}

fn hex_label(value: u32) -> Cow<'static, str> {
    Cow::Owned(format!("{value:04X}"))
}

/// A one-line view's text with each special character written as its mark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Revealed {
    pub text: String,
    pub marks: Vec<Mark>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mark {
    /// Bytes of the revealed text the mark takes.
    pub range: Range<usize>,
    pub labelled: bool,
}

/// `None` when `text` holds nothing to mark, so a plain value costs no copy.
pub fn reveal(text: &str) -> Option<Revealed> {
    let mut found = special_characters(text, true).peekable();
    found.peek()?;
    let mut shown = String::with_capacity(text.len() + 8);
    let mut marks = Vec::new();
    let mut copied = 0;
    for Classified { range, character } in found {
        shown.push_str(&text[copied..range.start]);
        let start = shown.len();
        let labelled = match character {
            SpecialCharacter::Marker(label) => {
                shown.push_str(&label);
                true
            }
            SpecialCharacter::BlankSpace => {
                shown.push_str(&text[range.clone()]);
                false
            }
        };
        marks.push(Mark {
            range: start..shown.len(),
            labelled,
        });
        copied = range.end;
    }
    shown.push_str(&text[copied..]);
    Some(Revealed { text: shown, marks })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marked(text: &str, line_breaks: bool) -> Vec<(Range<usize>, SpecialCharacter)> {
        special_characters(text, line_breaks)
            .map(|found| (found.range, found.character))
            .collect()
    }

    fn marker(label: &str) -> SpecialCharacter {
        SpecialCharacter::Marker(Cow::Owned(label.to_owned()))
    }

    #[test]
    fn plain_text_spaces_and_tabs_are_not_marked() {
        assert!(marked("plain text\twith a tab", true).is_empty());
        assert!(marked("ünïcödé 日本語", true).is_empty());
        assert_eq!(reveal("plain text"), None);
    }

    #[test]
    fn line_breaks_are_marked_only_in_a_one_line_view() {
        assert!(marked("one\ntwo\r\n", false).is_empty());
        assert_eq!(
            marked("one\ntwo\r\n", true),
            [(3..4, marker("LF")), (7..8, marker("CR")), (8..9, marker("LF"))]
        );
    }

    #[test]
    fn controls_take_their_names() {
        assert_eq!(
            marked("\u{1}\u{1b}\u{7f}\u{85}\u{9f}", false),
            [
                (0..1, marker("SOH")),
                (1..2, marker("ESC")),
                (2..3, marker("DEL")),
                (3..5, marker("NEL")),
                (5..7, marker("APC")),
            ]
        );
    }

    #[test]
    fn special_spaces_keep_their_width() {
        for space in [
            '\u{a0}', '\u{1680}', '\u{2000}', '\u{2007}', '\u{200a}', '\u{202f}', '\u{205f}', '\u{3000}',
        ] {
            let text = format!("a{space}b");
            assert_eq!(
                marked(&text, false),
                [(1..1 + space.len_utf8(), SpecialCharacter::BlankSpace)],
                "U+{:04X}",
                u32::from(space)
            );
        }
    }

    #[test]
    fn format_characters_take_their_short_names() {
        let cases = [
            ('\u{ad}', "SHY"),
            ('\u{200b}', "ZWSP"),
            ('\u{200e}', "LRM"),
            ('\u{2028}', "LSEP"),
            ('\u{2029}', "PSEP"),
            ('\u{202e}', "RLO"),
            ('\u{2060}', "WJ"),
            ('\u{2066}', "LRI"),
            ('\u{feff}', "BOM"),
            ('\u{fff9}', "IAA"),
            ('\u{3164}', "3164"),
            ('\u{2061}', "2061"),
            ('\u{1d173}', "1D173"),
            ('\u{e0001}', "E0001"),
        ];
        for (character, label) in cases {
            let text = format!("x{character}y");
            assert_eq!(
                marked(&text, false),
                [(1..1 + character.len_utf8(), marker(label))],
                "U+{:04X}",
                u32::from(character)
            );
        }
    }

    #[test]
    fn joiners_inside_non_ascii_text_are_left_alone() {
        assert!(marked("👨\u{200d}👩", false).is_empty());
        assert!(marked("क\u{200c}ष", false).is_empty());
        assert_eq!(marked("a\u{200d}b", false), [(1..4, marker("ZWJ"))]);
        assert_eq!(marked("\u{200c}", false), [(0..3, marker("ZWNJ"))]);
    }

    #[test]
    fn shaping_selectors_and_combining_ignorables_are_left_alone() {
        assert!(marked("✌\u{fe0f}", false).is_empty());
        assert!(marked("a\u{e0100}", false).is_empty());
        assert!(marked("e\u{34f}\u{180b}\u{17b4}\u{115f}", false).is_empty());
    }

    #[test]
    fn tags_mark_only_outside_an_emoji_tag_sequence() {
        let flag = "\u{1f3f4}\u{e0067}\u{e0062}\u{e0073}\u{e0063}\u{e0074}\u{e007f}";
        assert!(marked(flag, false).is_empty());
        assert_eq!(marked("a\u{e0067}", false), [(1..5, marker("E0067"))]);
        let broken = format!("{flag}x\u{e0067}");
        assert_eq!(
            marked(&broken, false),
            [(broken.len() - 4..broken.len(), marker("E0067"))]
        );
    }

    #[test]
    fn marks_stop_at_the_cap() {
        let text = "\u{1}".repeat(MAX_MARKS + 10);
        assert_eq!(special_characters(&text, false).count(), MAX_MARKS);
    }

    #[test]
    fn reveal_writes_labels_and_keeps_special_spaces() {
        let revealed = reveal("a\u{200b}b\u{a0}c\nd").expect("marks");
        assert_eq!(revealed.text, "aZWSPb\u{a0}cLFd");
        assert_eq!(
            revealed.marks,
            [
                Mark {
                    range: 1..5,
                    labelled: true
                },
                Mark {
                    range: 6..8,
                    labelled: false
                },
                Mark {
                    range: 9..11,
                    labelled: true
                },
            ]
        );
    }
}
