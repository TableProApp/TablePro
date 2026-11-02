use tablepro_core::sql_syntax::script::LexicalSettings;
use tablepro_core::sql_syntax::{SqlGrammar, SyntaxKind, syntax_tokens};

use crate::window_abi::TpSyntaxToken;

/// The grammar codes of `tablepro_syntax_tokens`, in `SqlGrammar`'s
/// declaration order.
const GRAMMARS: [SqlGrammar; 9] = [
    SqlGrammar::PostgreSql,
    SqlGrammar::MySql,
    SqlGrammar::Sqlite,
    SqlGrammar::MsSql,
    SqlGrammar::ClickHouse,
    SqlGrammar::DuckDb,
    SqlGrammar::Cql,
    SqlGrammar::Redis,
    SqlGrammar::Mongo,
];

/// Writes the tokens of `units` to `out` with UTF-16 offsets and returns
/// how many it wrote. `None` for an unknown grammar code.
pub(crate) fn scan(grammar: u32, backslash_escapes: u32, units: &[u16], out: &mut [TpSyntaxToken]) -> Option<usize> {
    let grammar = *GRAMMARS.get(usize::try_from(grammar).ok()?)?;
    let settings = match backslash_escapes {
        0 => LexicalSettings {
            backslash_escapes: false,
        },
        1 => LexicalSettings {
            backslash_escapes: true,
        },
        _ => LexicalSettings::default_for(grammar),
    };
    // A lone surrogate becomes U+FFFD, which is one unit too, so the
    // offsets mapped back still index `units`.
    let text = String::from_utf16_lossy(units);
    let mut units_at = Utf16Offsets::new(&text);
    let mut written = 0;
    for (token, slot) in syntax_tokens(&text, grammar, settings).into_iter().zip(out.iter_mut()) {
        let start = units_at.at(token.range.start);
        let end = units_at.at(token.range.end);
        *slot = TpSyntaxToken {
            start: u32::try_from(start).ok()?,
            length: u32::try_from(end - start).ok()?,
            kind: kind_code(token.kind),
        };
        written += 1;
    }
    Some(written)
}

fn kind_code(kind: SyntaxKind) -> u32 {
    match kind {
        SyntaxKind::Identifier => 0,
        SyntaxKind::Keyword => 1,
        SyntaxKind::String => 2,
        SyntaxKind::QuotedIdentifier => 3,
        SyntaxKind::Number => 4,
        SyntaxKind::Comment => 5,
        SyntaxKind::Operator => 6,
        SyntaxKind::Punctuation => 7,
    }
}

/// UTF-16 offsets of byte offsets that never go back, so a whole token
/// list maps in one pass over the text.
struct Utf16Offsets<'a> {
    text: &'a str,
    byte: usize,
    units: usize,
}

impl<'a> Utf16Offsets<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            byte: 0,
            units: 0,
        }
    }

    fn at(&mut self, byte: usize) -> usize {
        let mut next = self.byte;
        for c in self.text.get(self.byte..).unwrap_or_default().chars() {
            if next >= byte {
                break;
            }
            self.units += c.len_utf16();
            next += c.len_utf8();
        }
        self.byte = next;
        self.units
    }
}
