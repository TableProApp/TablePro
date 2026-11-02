//! The editor's token scan through the C ABI, with offsets in UTF-16 units.

#![expect(
    clippy::unwrap_used,
    reason = "the helpers fail a test the way the test functions themselves do"
)]

use tablepro_ffi::window_abi::{TpSyntaxToken, tablepro_syntax_tokens};

const POSTGRESQL: u32 = 0;
const MYSQL: u32 = 1;
const DEFAULT_ESCAPES: u32 = 2;

const KEYWORD: u32 = 1;
const STRING: u32 = 2;
const NUMBER: u32 = 4;
const COMMENT: u32 = 5;
const PUNCTUATION: u32 = 7;

fn scan(grammar: u32, text: &str) -> Vec<(u32, String)> {
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut tokens = vec![TpSyntaxToken::default(); units.len()];
    let len = u32::try_from(units.len()).unwrap();
    // SAFETY: both buffers hold the lengths passed.
    let written =
        unsafe { tablepro_syntax_tokens(grammar, DEFAULT_ESCAPES, units.as_ptr(), len, tokens.as_mut_ptr(), len) };
    tokens
        .iter()
        .take(usize::try_from(written).unwrap())
        .map(|token| {
            let start = usize::try_from(token.start).unwrap();
            let end = start + usize::try_from(token.length).unwrap();
            (token.kind, String::from_utf16(&units[start..end]).unwrap())
        })
        .collect()
}

#[test]
fn offsets_count_utf16_units_past_a_surrogate_pair() {
    let tokens = scan(POSTGRESQL, "select '😀' as x; -- 😀 done\nselect 1");
    assert_eq!(
        tokens,
        vec![
            (KEYWORD, "select".to_owned()),
            (STRING, "'😀'".to_owned()),
            (KEYWORD, "as".to_owned()),
            (0, "x".to_owned()),
            (PUNCTUATION, ";".to_owned()),
            (COMMENT, "-- 😀 done".to_owned()),
            (KEYWORD, "select".to_owned()),
            (NUMBER, "1".to_owned()),
        ]
    );
}

#[test]
fn vietnamese_text_maps_back_to_its_units() {
    let tokens = scan(MYSQL, "insert into t values ('Đơn hàng số 1', N'tiếng việt');");
    assert!(tokens.contains(&(STRING, "'Đơn hàng số 1'".to_owned())));
    assert!(tokens.contains(&(STRING, "'tiếng việt'".to_owned())));
}

#[test]
fn a_lone_surrogate_keeps_the_offsets_in_step() {
    let mut units: Vec<u16> = "select ".encode_utf16().collect();
    units.push(0xD800);
    units.extend("from".encode_utf16());
    let mut tokens = vec![TpSyntaxToken::default(); units.len()];
    let len = u32::try_from(units.len()).unwrap();
    // SAFETY: both buffers hold the lengths passed.
    let written = unsafe { tablepro_syntax_tokens(POSTGRESQL, 0, units.as_ptr(), len, tokens.as_mut_ptr(), len) };
    assert_eq!(written, 2);
    assert_eq!((tokens[0].start, tokens[0].length), (0, 6));
    // The replacement character joins the word it touches, one unit wide.
    assert_eq!((tokens[1].start, tokens[1].length), (7, 5));
}

#[test]
fn writes_no_more_than_capacity() {
    let units: Vec<u16> = "a b c d".encode_utf16().collect();
    let mut tokens = vec![TpSyntaxToken::default(); 2];
    let len = u32::try_from(units.len()).unwrap();
    // SAFETY: `tokens` holds the capacity passed.
    let written = unsafe { tablepro_syntax_tokens(POSTGRESQL, 0, units.as_ptr(), len, tokens.as_mut_ptr(), 2) };
    assert_eq!(written, 2);
}

#[test]
fn refuses_null_pointers_and_unknown_grammars() {
    let units: Vec<u16> = "select 1".encode_utf16().collect();
    let mut tokens = vec![TpSyntaxToken::default(); units.len()];
    let len = u32::try_from(units.len()).unwrap();
    // SAFETY: a null pointer is refused before any read; the rest hold their lengths.
    unsafe {
        assert_eq!(
            tablepro_syntax_tokens(POSTGRESQL, 0, std::ptr::null(), len, tokens.as_mut_ptr(), len),
            0
        );
        assert_eq!(
            tablepro_syntax_tokens(POSTGRESQL, 0, units.as_ptr(), len, std::ptr::null_mut(), len),
            0
        );
        assert_eq!(
            tablepro_syntax_tokens(9, 0, units.as_ptr(), len, tokens.as_mut_ptr(), len),
            0
        );
        assert_eq!(
            tablepro_syntax_tokens(7, 0, units.as_ptr(), len, tokens.as_mut_ptr(), len),
            0
        );
    }
}
