use std::num::NonZeroU32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GoLine {
    pub start: usize,
    pub end: usize,
    pub repeat: NonZeroU32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DelimiterLine<'a> {
    pub start: usize,
    pub end: usize,
    pub delimiter: Option<&'a str>,
}

pub(crate) fn go_line(text: &str, line_start: usize) -> Option<GoLine> {
    let (start, line) = trimmed_line(text, line_start);
    let rest = strip_keyword(line, "go")?;
    let after_spaces = rest.trim_start_matches(is_line_space);
    let digits = after_spaces.len() - after_spaces.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let (repeat, tail) = if digits > 0 && after_spaces.len() < rest.len() {
        let count = after_spaces[..digits].parse::<u32>().ok().and_then(NonZeroU32::new)?;
        (count, &after_spaces[digits..])
    } else {
        (NonZeroU32::MIN, rest)
    };
    let tail = tail.trim_start_matches(is_line_space);
    if !(tail.is_empty() || tail.starts_with("--")) {
        return None;
    }
    Some(GoLine {
        start,
        end: line_end(text, line_start),
        repeat,
    })
}

pub(crate) fn delimiter_line(text: &str, line_start: usize) -> Option<DelimiterLine<'_>> {
    let (start, line) = trimmed_line(text, line_start);
    let rest = strip_keyword(line, "delimiter").or_else(|| strip_keyword(line, "\\d"))?;
    let argument = rest.trim_start_matches(is_line_space);
    let delimiter = match argument.chars().next() {
        Some(quote @ ('\'' | '"' | '`')) => argument[1..].split(quote).next(),
        Some(_) => argument.split(is_line_space).next(),
        None => None,
    }
    .filter(|delimiter| !delimiter.is_empty() && !delimiter.contains('\\'));
    Some(DelimiterLine {
        start,
        end: line_end(text, line_start),
        delimiter,
    })
}

fn trimmed_line(text: &str, line_start: usize) -> (usize, &str) {
    let line = &text[line_start..line_end(text, line_start)];
    let trimmed = line.trim_start_matches(is_line_space);
    (line_start + line.len() - trimmed.len(), trimmed)
}

fn line_end(text: &str, line_start: usize) -> usize {
    text[line_start..]
        .find('\n')
        .map_or(text.len(), |offset| line_start + offset)
}

fn strip_keyword<'a>(line: &'a str, keyword: &str) -> Option<&'a str> {
    let head = line.get(..keyword.len())?;
    if !head.eq_ignore_ascii_case(keyword) {
        return None;
    }
    let rest = &line[keyword.len()..];
    let boundary = rest.is_empty() || rest.starts_with(is_line_space) || rest.starts_with("--");
    boundary.then_some(rest)
}

fn is_line_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\x0b' | '\x0c')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_line_accepts_count_and_comment() {
        let text = "  go 3 -- again\nSELECT 1";
        assert_eq!(
            go_line(text, 0),
            Some(GoLine {
                start: 2,
                end: 15,
                repeat: NonZeroU32::new(3).unwrap()
            })
        );
        assert_eq!(go_line("GO", 0).map(|line| line.repeat), Some(NonZeroU32::MIN));
    }

    #[test]
    fn go_line_rejects_other_text() {
        for text in ["GO;", "GOTO x", "GO 0", "GO 3 x", "SELECT 1 GO"] {
            assert_eq!(go_line(text, 0), None, "{text:?}");
        }
    }

    #[test]
    fn delimiter_line_reads_the_argument() {
        assert_eq!(
            delimiter_line("DELIMITER $$\n", 0).and_then(|line| line.delimiter),
            Some("$$")
        );
        assert_eq!(delimiter_line("\\d //", 0).and_then(|line| line.delimiter), Some("//"));
        assert_eq!(
            delimiter_line("delimiter ';;'", 0).and_then(|line| line.delimiter),
            Some(";;")
        );
        assert_eq!(delimiter_line("DELIMITER", 0).map(|line| line.delimiter), Some(None));
        assert_eq!(delimiter_line("DELIMITERS $$", 0), None);
    }
}
