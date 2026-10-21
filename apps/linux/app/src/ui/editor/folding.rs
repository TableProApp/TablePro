use std::ops::Range;

use relm4::gtk;
use sourceview5::prelude::*;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

#[derive(Debug, Clone, Eq, PartialEq)]
pub(super) struct FoldRange {
    pub(super) extent: Range<usize>,
    pub(super) header: usize,
    pub(super) hidden: Range<usize>,
}

pub(super) struct FoldController {
    tag: gtk::TextTag,
    folded: Vec<FoldRange>,
}

impl FoldController {
    pub(super) fn new(buffer: &gtk::TextBuffer) -> Self {
        let tag = gtk::TextTag::new(Some("sql-fold"));
        tag.set_invisible(true);
        buffer.tag_table().add(&tag);
        Self {
            tag,
            folded: Vec::new(),
        }
    }

    pub(super) fn install(&self, view: &sourceview5::View) {
        let attributes = sourceview5::MarkAttributes::new();
        attributes.set_icon_name("pan-down-symbolic");
        view.set_mark_attributes("sql-fold", &attributes, 10);
    }

    pub(super) fn toggle_at_cursor(
        &mut self,
        buffer: &sourceview5::Buffer,
        grammar: SqlGrammar,
        settings: LexicalSettings,
    ) {
        let (start, end) = buffer.bounds();
        let sql = buffer.text(&start, &end, true).to_string();
        let cursor = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
        let cursor = cursor_byte_offset(&sql, cursor);
        let Some(region) = range_at_cursor(&sql, grammar, settings, cursor) else {
            return;
        };
        if let Some(index) = self.folded.iter().position(|folded| folded.extent == region.extent) {
            self.folded.remove(index);
            self.render(buffer);
            return;
        }
        self.apply(buffer, region);
    }

    pub(super) fn unfold_line(&mut self, buffer: &sourceview5::Buffer, line: i32) {
        let Some(index) = self
            .folded
            .iter()
            .position(|region| byte_line(buffer, region.header) == line)
        else {
            return;
        };
        self.folded.remove(index);
        self.render(buffer);
    }

    pub(super) fn unfold_all(&mut self, buffer: &sourceview5::Buffer) {
        self.folded.clear();
        self.render(buffer);
    }

    pub(super) fn clear(&mut self, buffer: &sourceview5::Buffer) {
        self.folded.clear();
        self.render(buffer);
    }

    fn apply(&mut self, buffer: &sourceview5::Buffer, region: FoldRange) {
        self.folded.push(region);
        self.render(buffer);
    }

    fn render(&self, buffer: &sourceview5::Buffer) {
        buffer.remove_tag(&self.tag, &buffer.start_iter(), &buffer.end_iter());
        clear_marks(buffer);
        for region in &self.folded {
            apply_byte_range(buffer, &region.hidden, |start, end| {
                buffer.apply_tag(&self.tag, &start, &end)
            });
            if let Some(iter) = buffer.iter_at_line(byte_line(buffer, region.header)) {
                buffer.create_source_mark(None, "sql-fold", &iter);
            }
        }
    }
}

fn clear_marks(buffer: &sourceview5::Buffer) {
    buffer.remove_source_marks(&buffer.start_iter(), &buffer.end_iter(), Some("sql-fold"));
}

fn apply_byte_range(
    buffer: &sourceview5::Buffer,
    bytes: &Range<usize>,
    apply: impl FnOnce(gtk::TextIter, gtk::TextIter),
) {
    let (start, end) = buffer.bounds();
    let sql = buffer.text(&start, &end, true).to_string();
    let start = sql.get(..bytes.start).unwrap_or_default().chars().count() as i32;
    let end = sql.get(..bytes.end).unwrap_or_default().chars().count() as i32;
    apply(buffer.iter_at_offset(start), buffer.iter_at_offset(end));
}

fn byte_line(buffer: &sourceview5::Buffer, byte: usize) -> i32 {
    let (start, end) = buffer.bounds();
    buffer
        .text(&start, &end, true)
        .get(..byte)
        .unwrap_or_default()
        .matches('\n')
        .count() as i32
}

fn cursor_byte_offset(sql: &str, chars: usize) -> usize {
    sql.char_indices().nth(chars).map_or(sql.len(), |(byte, _)| byte)
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum BlockKind {
    Begin,
    Case,
    If,
    Loop,
    Repeat,
    While,
}

pub(super) fn range_at_cursor(
    sql: &str,
    grammar: SqlGrammar,
    settings: LexicalSettings,
    cursor: usize,
) -> Option<FoldRange> {
    fold_ranges(sql, grammar, settings)
        .into_iter()
        .filter(|region| region.extent.start <= cursor && cursor <= region.extent.end)
        .min_by_key(|region| region.extent.end.saturating_sub(region.extent.start))
}

fn fold_ranges(sql: &str, grammar: SqlGrammar, settings: LexicalSettings) -> Vec<FoldRange> {
    let mut ranges = Vec::new();
    collect_ranges(sql, (grammar, settings), 0, 0, &mut ranges);
    ranges.sort_by_key(|region| (region.extent.start, region.extent.end));
    ranges
}

fn collect_ranges(
    sql: &str,
    (grammar, settings): (SqlGrammar, LexicalSettings),
    base: usize,
    depth: usize,
    ranges: &mut Vec<FoldRange>,
) {
    let plan = ScriptPlan::build(sql, grammar, settings);
    let tokens: Vec<ScriptToken> = plan.tokens(0..sql.len()).collect();
    collect_parenthesis_ranges(sql, &tokens, base, ranges);
    collect_block_ranges(sql, &tokens, base, ranges);
    collect_comment_ranges(sql, (grammar, settings), &tokens, base, depth, ranges);
}

fn collect_parenthesis_ranges(sql: &str, tokens: &[ScriptToken], base: usize, ranges: &mut Vec<FoldRange>) {
    let mut open = Vec::new();
    for token in tokens {
        match token.kind {
            ScriptTokenKind::OpenParen => open.push(token.range.clone()),
            ScriptTokenKind::CloseParen => {
                if let Some(start) = open.pop() {
                    push_range(
                        sql,
                        start.start..token.range.end,
                        start.end,
                        token.range.start,
                        base,
                        ranges,
                    );
                }
            }
            _ => {}
        }
    }
}

fn collect_block_ranges(sql: &str, tokens: &[ScriptToken], base: usize, ranges: &mut Vec<FoldRange>) {
    let mut open: Vec<(BlockKind, Range<usize>)> = Vec::new();
    let mut skip = None;
    for (index, token) in tokens.iter().enumerate() {
        if skip == Some(index) || token.kind != ScriptTokenKind::Word {
            continue;
        }
        let word = token_text(sql, token).to_ascii_uppercase();
        if word == "END" {
            let next = next_significant(tokens, index).map(|next| (next, &tokens[next]));
            close_block(sql, next, token, &mut open, &mut skip, base, ranges);
            continue;
        }
        if let Some(kind) = opener_kind(&word)
            && !(kind == BlockKind::If && next_kind(tokens, index) == Some(ScriptTokenKind::OpenParen))
        {
            open.push((kind, token.range.clone()));
        }
    }
}

fn close_block(
    sql: &str,
    next: Option<(usize, &ScriptToken)>,
    token: &ScriptToken,
    open: &mut Vec<(BlockKind, Range<usize>)>,
    skip: &mut Option<usize>,
    base: usize,
    ranges: &mut Vec<FoldRange>,
) {
    let Some((next_index, next_token)) = next else {
        close_last(sql, token, open, base, ranges);
        return;
    };
    let suffix = token_text(sql, next_token).to_ascii_uppercase();
    if let Some(suffix_kind) = opener_kind(&suffix) {
        *skip = Some(next_index);
        if open.last().is_some_and(|(kind, _)| *kind == suffix_kind) {
            close_last(sql, token, open, base, ranges);
        }
        return;
    }
    if matches!(suffix.as_str(), "TRY" | "CATCH") {
        *skip = Some(next_index);
    }
    close_last(sql, token, open, base, ranges);
}

fn close_last(
    sql: &str,
    token: &ScriptToken,
    open: &mut Vec<(BlockKind, Range<usize>)>,
    base: usize,
    ranges: &mut Vec<FoldRange>,
) {
    if let Some((_, start)) = open.pop() {
        push_range(
            sql,
            start.start..token.range.end,
            start.end,
            token.range.start,
            base,
            ranges,
        );
    }
}

fn collect_comment_ranges(
    sql: &str,
    (grammar, settings): (SqlGrammar, LexicalSettings),
    tokens: &[ScriptToken],
    base: usize,
    depth: usize,
    ranges: &mut Vec<FoldRange>,
) {
    for token in tokens {
        let text = token_text(sql, token);
        if token.kind == ScriptTokenKind::BlockComment && text.starts_with("/*") && text.ends_with("*/") {
            push_range(
                sql,
                token.range.clone(),
                token.range.start + 2,
                token.range.end - 2,
                base,
                ranges,
            );
        }
        if depth >= 8 || grammar != SqlGrammar::PostgreSql || token.kind != ScriptTokenKind::DollarQuoted {
            continue;
        }
        let Some(body) = dollar_body(text) else {
            continue;
        };
        collect_ranges(
            &text[body.clone()],
            (grammar, settings),
            base + token.range.start + body.start,
            depth + 1,
            ranges,
        );
    }
}

fn dollar_body(text: &str) -> Option<Range<usize>> {
    let delimiter_end = text.get(1..)?.find('$')? + 1;
    let delimiter = text.get(..=delimiter_end)?;
    let body_end = text.len().checked_sub(delimiter.len())?;
    (body_end >= delimiter.len() && text.ends_with(delimiter)).then_some(delimiter.len()..body_end)
}

fn push_range(
    sql: &str,
    extent: Range<usize>,
    opener_end: usize,
    closer_start: usize,
    base: usize,
    ranges: &mut Vec<FoldRange>,
) {
    let Some(opening_newline) = sql.get(opener_end..).and_then(|rest| rest.find('\n')) else {
        return;
    };
    let hidden_start = opener_end + opening_newline + 1;
    let Some(closing_line_offset) = sql.get(..closer_start).and_then(|prefix| prefix.rfind('\n')) else {
        return;
    };
    let hidden_end = closing_line_offset + 1;
    if hidden_start >= hidden_end
        || !sql
            .get(hidden_start..hidden_end)
            .is_some_and(|hidden| hidden.chars().any(|character| !character.is_whitespace()))
    {
        return;
    }
    let header = sql
        .get(..extent.start)
        .and_then(|prefix| prefix.rfind('\n'))
        .map_or(0, |line| line + 1);
    ranges.push(FoldRange {
        extent: base + extent.start..base + extent.end,
        header: base + header,
        hidden: base + hidden_start..base + hidden_end,
    });
}

fn opener_kind(word: &str) -> Option<BlockKind> {
    match word {
        "BEGIN" => Some(BlockKind::Begin),
        "CASE" => Some(BlockKind::Case),
        "IF" => Some(BlockKind::If),
        "LOOP" => Some(BlockKind::Loop),
        "REPEAT" => Some(BlockKind::Repeat),
        "WHILE" => Some(BlockKind::While),
        _ => None,
    }
}

fn next_significant(tokens: &[ScriptToken], index: usize) -> Option<usize> {
    tokens
        .get(index + 1..)?
        .iter()
        .position(|token| !token.kind.is_trivia())
        .map(|next| index + 1 + next)
}

fn next_kind(tokens: &[ScriptToken], index: usize) -> Option<ScriptTokenKind> {
    next_significant(tokens, index).map(|next| tokens[next].kind)
}

fn token_text<'a>(sql: &'a str, token: &ScriptToken) -> &'a str {
    sql.get(token.range.clone()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::sql_syntax::SqlGrammar;

    #[test]
    fn folds_the_innermost_multiline_parenthesized_region() {
        let sql = "SELECT (\n  COALESCE(value, (\n    1\n  ))\nFROM items;";
        let cursor = sql.find("1\n").unwrap();
        let region = range_at_cursor(
            sql,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
            cursor,
        )
        .unwrap();
        assert_eq!(&sql[region.hidden.clone()], "    1\n");
    }

    #[test]
    fn folds_nested_case_blocks_without_hiding_the_end_lines() {
        let sql = "SELECT CASE\n  WHEN a THEN CASE\n    WHEN b THEN 1\n    ELSE 2\n  END\n  ELSE 3\nEND;";
        let cursor = sql.find("WHEN b").unwrap();
        let region = range_at_cursor(
            sql,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
            cursor,
        )
        .unwrap();
        assert_eq!(&sql[region.hidden.clone()], "    WHEN b THEN 1\n    ELSE 2\n");
    }

    #[test]
    fn ignores_delimiters_and_block_words_inside_comments_and_literals() {
        let sql = "SELECT (\n  'END )' AS value,\n  /* BEGIN\n  )\n  END */\n  1\n);";
        let cursor = sql.find("END )").unwrap();
        let region = range_at_cursor(
            sql,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
            cursor,
        )
        .unwrap();
        assert_eq!(region.extent, 7..sql.rfind(')').unwrap() + 1);
    }

    #[test]
    fn folds_plpgsql_blocks_with_dollar_quoted_bodies() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$\nBEGIN\n  RETURN 1;\nEND;\n$$ LANGUAGE plpgsql;";
        let cursor = sql.find("  RETURN").unwrap();
        let region = range_at_cursor(
            sql,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
            cursor,
        )
        .unwrap();
        assert_eq!(&sql[region.hidden.clone()], "  RETURN 1;\n");
    }

    #[test]
    fn an_unmatched_opener_does_not_create_a_fold() {
        let sql = "SELECT (\n  1;";
        assert!(
            range_at_cursor(
                sql,
                SqlGrammar::PostgreSql,
                LexicalSettings::default_for(SqlGrammar::PostgreSql),
                sql.find('1').unwrap()
            )
            .is_none()
        );
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn folding_hides_lines_without_changing_query_text_and_can_be_cleared() {
        relm4::adw::init().unwrap();
        let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
        let sql = "SELECT CASE\n  WHEN ready THEN 1\nEND;";
        buffer.set_text(sql);
        let mut controller = FoldController::new(buffer.upcast_ref());
        buffer.place_cursor(&buffer.iter_at_offset(sql.find("ready").unwrap() as i32));
        controller.toggle_at_cursor(
            &buffer,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
        );
        let (start, end) = buffer.bounds();
        assert_eq!(buffer.text(&start, &end, true), sql);
        let hidden_line = buffer.iter_at_line(1).unwrap();
        assert!(hidden_line.has_tag(&controller.tag));
        controller.clear(&buffer);
        assert!(!hidden_line.has_tag(&controller.tag));
    }
}
