use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDelimiter {
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

impl CsvDelimiter {
    pub const ALL: [CsvDelimiter; 4] = [
        CsvDelimiter::Comma,
        CsvDelimiter::Semicolon,
        CsvDelimiter::Tab,
        CsvDelimiter::Pipe,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvQuote {
    Always,
    IfNeeded,
    Never,
}

impl CsvQuote {
    pub const ALL: [CsvQuote; 3] = [CsvQuote::Always, CsvQuote::IfNeeded, CsvQuote::Never];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvLineBreak {
    Lf,
    CrLf,
    Cr,
}

impl CsvLineBreak {
    pub const ALL: [CsvLineBreak; 3] = [CsvLineBreak::Lf, CsvLineBreak::CrLf, CsvLineBreak::Cr];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CsvDecimal {
    Period,
    Comma,
}

impl CsvDecimal {
    pub const ALL: [CsvDecimal; 2] = [CsvDecimal::Period, CsvDecimal::Comma];
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CsvOptions {
    pub null_to_empty: bool,
    pub line_break_to_space: bool,
    pub header_row: bool,
    pub sanitize_formulas: bool,
    pub delimiter: CsvDelimiter,
    pub quote: CsvQuote,
    pub line_break: CsvLineBreak,
    pub decimal: CsvDecimal,
}

impl Default for CsvOptions {
    fn default() -> Self {
        CsvOptions {
            null_to_empty: true,
            line_break_to_space: false,
            header_row: true,
            // RFC 4180 carries a field as written, and OWASP scopes the quote prefix to files meant
            // for a spreadsheet: an importer keeps the quote as part of the value.
            sanitize_formulas: false,
            delimiter: CsvDelimiter::Comma,
            quote: CsvQuote::IfNeeded,
            line_break: CsvLineBreak::Lf,
            decimal: CsvDecimal::Period,
        }
    }
}
