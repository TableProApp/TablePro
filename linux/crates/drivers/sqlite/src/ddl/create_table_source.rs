//! The CREATE TABLE text SQLite stored for a table, read into the
//! pieces a rebuild splices: each column with its constraints, the
//! table constraints, and the options after the list.
//!
//! The reader follows the grammar of lang_createtable.html over the
//! script lexer's tokens, the lexer the editor splits scripts with and
//! that is tested against `sqlite3_complete`. A quoted name, a string
//! or a comment is one token there, and every token carries its bytes,
//! so what a rebuild does not change goes into the new table as it was
//! written.

use std::collections::HashSet;
use std::ops::Range;

use tablepro_core::ddl::TableDefinition;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

use super::column_constraint_segment::{ColumnConstraintKind, ColumnConstraintSegment};
use super::declared_shape::DeclaredShape;
use super::source_element::{
    ElementKind, ForeignKeyTarget, SourceColumn, SourceElement, SourceForeignKey, TableConstraint, TableConstraintKind,
};
use super::source_read_error::SourceReadError;

/// One token that is not whitespace or a comment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Token {
    pub kind: ScriptTokenKind,
    pub range: Range<usize>,
}

/// The tokens of `sql` without whitespace and comments. An unclosed
/// string, name or comment makes the text unreadable.
pub(crate) fn tokens(sql: &str) -> Result<Vec<Token>, SourceReadError> {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    let mut tokens: Vec<Token> = Vec::new();
    for token in plan.tokens(0..sql.len()) {
        match token.kind {
            ScriptTokenKind::Unterminated => return Err(SourceReadError::Unterminated),
            kind if kind.is_trivia() => {}
            // The lexer reads `X'00'` as a word and a string; SQLite reads
            // one blob literal.
            ScriptTokenKind::StringLiteral
                if tokens.last().is_some_and(|last| {
                    last.kind == ScriptTokenKind::Word
                        && last.range.end == token.range.start
                        && sql
                            .get(last.range.clone())
                            .is_some_and(|word| word.eq_ignore_ascii_case("x"))
                }) =>
            {
                if let Some(last) = tokens.last_mut() {
                    last.kind = ScriptTokenKind::StringLiteral;
                    last.range.end = token.range.end;
                }
            }
            kind => tokens.push(Token {
                kind,
                range: token.range,
            }),
        }
    }
    Ok(tokens)
}

/// A table's CREATE TABLE statement, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CreateTableSource<'a> {
    sql: &'a str,
    tokens: Vec<Token>,
    /// The table's name, quotes removed.
    pub table: String,
    /// The byte of the `(` that opens the list.
    pub open: usize,
    /// The byte of the `)` that closes it.
    pub close: usize,
    pub elements: Vec<SourceElement>,
    /// Everything after the closing `)`, such as ` WITHOUT ROWID`.
    pub options: Range<usize>,
    pub without_rowid: bool,
}

impl<'a> CreateTableSource<'a> {
    pub(crate) fn read(sql: &'a str) -> Result<Self, SourceReadError> {
        let tokens = tokens(sql)?;
        let mut reader = Reader {
            sql,
            tokens: &tokens,
            position: 0,
        };
        let (table, open) = reader.head()?;
        let elements = reader.elements()?;
        let close = reader.close()?;
        let (options, without_rowid) = reader.options()?;
        Ok(Self {
            sql,
            tokens,
            table,
            open,
            close,
            elements,
            options,
            without_rowid,
        })
    }

    /// The statement stored for `definition`, read and checked against
    /// what the catalogue says the table has.
    pub(crate) fn of(definition: &'a TableDefinition) -> Result<Self, SourceReadError> {
        let sql = definition
            .source
            .as_ref()
            .map(|source| source.create_statement.as_str())
            .ok_or(SourceReadError::Missing)?;
        let source = Self::read(sql)?;
        source.shape().check(definition)?;
        Ok(source)
    }

    pub(crate) fn shape(&self) -> DeclaredShape {
        DeclaredShape {
            table: self.table.clone(),
            columns: self.columns().map(|(_, column)| column.name.clone()).collect(),
            foreign_keys: self.foreign_keys().len(),
        }
    }

    pub(crate) fn sql(&self) -> &'a str {
        self.sql
    }

    pub(crate) fn text(&self, range: Range<usize>) -> &'a str {
        self.sql.get(range).unwrap_or_default()
    }

    /// The column elements with their index among all elements.
    pub(crate) fn columns(&self) -> impl Iterator<Item = (usize, &SourceColumn)> {
        self.elements
            .iter()
            .enumerate()
            .filter_map(|(index, element)| match &element.kind {
                ElementKind::Column(column) => Some((index, column)),
                ElementKind::Constraint(_) => None,
            })
    }

    /// The table constraints with their index among all elements.
    pub(crate) fn constraints(&self) -> impl Iterator<Item = (usize, &TableConstraint)> {
        self.elements
            .iter()
            .enumerate()
            .filter_map(|(index, element)| match &element.kind {
                ElementKind::Constraint(constraint) => Some((index, constraint)),
                ElementKind::Column(_) => None,
            })
    }

    /// Every foreign key in the order the text declares them. SQLite
    /// numbers them from the last: `pragma_foreign_key_list` id 0 is
    /// the last one here.
    pub(crate) fn foreign_keys(&self) -> Vec<SourceForeignKey<'_>> {
        let mut keys = Vec::new();
        for (index, element) in self.elements.iter().enumerate() {
            match &element.kind {
                ElementKind::Column(column) => {
                    for (position, segment) in column.segments.iter().enumerate() {
                        if let ColumnConstraintKind::References(target) = &segment.kind {
                            let name = position
                                .checked_sub(1)
                                .and_then(|before| column.segments.get(before))
                                .and_then(|before| match &before.kind {
                                    ColumnConstraintKind::Name(name) => Some(name.as_str()),
                                    _ => None,
                                });
                            keys.push(SourceForeignKey {
                                name,
                                element: index,
                                segment: Some(position),
                                columns: std::slice::from_ref(&column.name),
                                target,
                            });
                        }
                    }
                }
                ElementKind::Constraint(TableConstraint {
                    name,
                    kind: TableConstraintKind::ForeignKey { columns, target },
                }) => keys.push(SourceForeignKey {
                    name: name.as_deref(),
                    element: index,
                    segment: None,
                    columns,
                    target,
                }),
                ElementKind::Constraint(_) => {}
            }
        }
        keys
    }

    /// The column declared with AUTOINCREMENT, on its own PRIMARY KEY or
    /// in a table PRIMARY KEY of that one column.
    pub(crate) fn autoincrement_column(&self) -> Option<&str> {
        let inline = self.columns().find_map(|(_, column)| {
            column
                .segments
                .iter()
                .any(|segment| {
                    matches!(
                        segment.kind,
                        ColumnConstraintKind::PrimaryKey {
                            autoincrement: true,
                            ..
                        }
                    )
                })
                .then_some(column.name.as_str())
        });
        inline.or_else(|| {
            self.constraints().find_map(|(_, constraint)| match &constraint.kind {
                TableConstraintKind::PrimaryKey {
                    columns,
                    autoincrement: true,
                } => match columns.as_slice() {
                    [only] => Some(only.as_str()),
                    _ => None,
                },
                _ => None,
            })
        })
    }

    /// The names `range` mentions, lowercased and unquoted. A name inside
    /// a string literal is not a mention.
    pub(crate) fn mentions(&self, range: Range<usize>) -> HashSet<String> {
        self.tokens
            .iter()
            .filter(|token| token.range.start >= range.start && token.range.end <= range.end)
            .filter_map(|token| match token.kind {
                ScriptTokenKind::Word => Some(self.text(token.range.clone()).to_lowercase()),
                ScriptTokenKind::QuotedIdentifier => Some(unquote(self.text(token.range.clone())).to_lowercase()),
                _ => None,
            })
            .collect()
    }
}

/// The names a CREATE TABLE gives its foreign keys, in the order
/// `pragma_foreign_key_list` numbers them, which is from the last one
/// declared. `None` for a key declared without a name, and no list when
/// the text does not read.
pub(crate) fn declared_foreign_key_names(sql: &str) -> Option<Vec<Option<String>>> {
    let source = CreateTableSource::read(sql).ok()?;
    let mut names: Vec<Option<String>> = source
        .foreign_keys()
        .iter()
        .map(|key| key.name.map(str::to_owned))
        .collect();
    names.reverse();
    Some(names)
}

/// `"a""b"`, `` `a``b` ``, `[a b]` and `'a'` all name what SQLite
/// would read. A bare word is the name as written.
pub(crate) fn unquote(text: &str) -> String {
    let mut characters = text.chars();
    match (characters.next(), characters.next_back()) {
        (Some('['), Some(']')) => characters.as_str().to_owned(),
        (Some(open @ ('"' | '`' | '\'')), Some(close)) if open == close => {
            let doubled = format!("{open}{open}");
            characters.as_str().replace(&doubled, &open.to_string())
        }
        _ => text.to_owned(),
    }
}

/// Words that start a column constraint, where a column's type ends.
const COLUMN_CONSTRAINT_STARTS: &[&str] = &[
    "CONSTRAINT",
    "PRIMARY",
    "NOT",
    "NULL",
    "UNIQUE",
    "CHECK",
    "DEFAULT",
    "COLLATE",
    "REFERENCES",
    "AS",
];

const TABLE_CONSTRAINT_STARTS: &[&str] = &["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"];

struct Reader<'s, 't> {
    sql: &'s str,
    tokens: &'t [Token],
    position: usize,
}

impl Reader<'_, '_> {
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    fn text_of(&self, token: &Token) -> &str {
        self.sql.get(token.range.clone()).unwrap_or_default()
    }

    fn is_word(&self, ahead: usize, word: &str) -> bool {
        self.tokens
            .get(self.position + ahead)
            .is_some_and(|token| token.kind == ScriptTokenKind::Word && self.text_of(token).eq_ignore_ascii_case(word))
    }

    fn at(&self, word: &str) -> bool {
        self.is_word(0, word)
    }

    fn at_any(&self, words: &[&str]) -> bool {
        words.iter().any(|word| self.at(word))
    }

    fn at_kind(&self, kind: ScriptTokenKind) -> bool {
        self.peek().is_some_and(|token| token.kind == kind)
    }

    fn at_punct(&self, punct: &str) -> bool {
        self.peek()
            .is_some_and(|token| token.kind == ScriptTokenKind::Punct && self.text_of(token) == punct)
    }

    fn eat(&mut self, word: &str) -> bool {
        let found = self.at(word);
        if found {
            self.position += 1;
        }
        found
    }

    fn eat_any(&mut self, words: &[&str]) -> bool {
        words.iter().any(|word| self.eat(word))
    }

    fn expect(&mut self, word: &str) -> Result<(), SourceReadError> {
        match self.eat(word) {
            true => Ok(()),
            false => Err(self.unexpected()),
        }
    }

    fn unexpected(&self) -> SourceReadError {
        match self.peek() {
            Some(token) => SourceReadError::Unexpected {
                offset: token.range.start,
                found: self.text_of(token).to_owned(),
            },
            None => SourceReadError::Unterminated,
        }
    }

    /// The end of the last token read.
    fn last_end(&self) -> usize {
        self.position
            .checked_sub(1)
            .and_then(|last| self.tokens.get(last))
            .map_or(0, |token| token.range.end)
    }

    /// A name: a word, a quoted name, or a string, which SQLite also
    /// takes as a name.
    fn name(&mut self) -> Result<(String, Range<usize>), SourceReadError> {
        let Some(token) = self.peek().cloned() else {
            return Err(SourceReadError::Unterminated);
        };
        match token.kind {
            ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::StringLiteral => {
                self.position += 1;
                Ok((unquote(self.text_of(&token)), token.range))
            }
            _ => Err(self.unexpected()),
        }
    }

    /// A parenthesised group, up to the `)` that closes it.
    fn group(&mut self) -> Result<Range<usize>, SourceReadError> {
        let Some(open) = self
            .peek()
            .cloned()
            .filter(|token| token.kind == ScriptTokenKind::OpenParen)
        else {
            return Err(self.unexpected());
        };
        let mut depth = 0usize;
        while let Some(token) = self.peek().cloned() {
            self.position += 1;
            match token.kind {
                ScriptTokenKind::OpenParen => depth += 1,
                ScriptTokenKind::CloseParen => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(open.range.start..token.range.end);
                    }
                }
                _ => {}
            }
        }
        Err(SourceReadError::Unterminated)
    }

    /// `( name [COLLATE c] [ASC|DESC], ... )`, the names only.
    fn name_list(&mut self) -> Result<Vec<String>, SourceReadError> {
        if !self.at_kind(ScriptTokenKind::OpenParen) {
            return Err(self.unexpected());
        }
        self.position += 1;
        let mut names = Vec::new();
        loop {
            names.push(self.name()?.0);
            loop {
                let Some(token) = self.peek() else {
                    return Err(SourceReadError::Unterminated);
                };
                match token.kind {
                    ScriptTokenKind::CloseParen => {
                        self.position += 1;
                        return Ok(names);
                    }
                    ScriptTokenKind::OpenParen => {
                        self.group()?;
                    }
                    _ if self.at_punct(",") => {
                        self.position += 1;
                        break;
                    }
                    _ => self.position += 1,
                }
            }
        }
    }

    /// `CREATE [TEMP] TABLE [IF NOT EXISTS] [schema.]name (`, giving the
    /// name and the byte of the `(`.
    fn head(&mut self) -> Result<(String, usize), SourceReadError> {
        if !self.eat("CREATE") {
            return Err(SourceReadError::NotCreateTable);
        }
        self.eat_any(&["TEMP", "TEMPORARY"]);
        if !self.eat("TABLE") {
            return Err(SourceReadError::NotCreateTable);
        }
        if self.eat("IF") {
            self.expect("NOT")?;
            self.expect("EXISTS")?;
        }
        let (mut table, _) = self.name()?;
        if self.at_punct(".") {
            self.position += 1;
            table = self.name()?.0;
        }
        match self.peek() {
            Some(token) if token.kind == ScriptTokenKind::OpenParen => {
                let open = token.range.start;
                self.position += 1;
                Ok((table, open))
            }
            _ => Err(SourceReadError::NotCreateTable),
        }
    }

    /// The columns, then the table constraints, which SQLite lets follow
    /// one another without a comma.
    fn elements(&mut self) -> Result<Vec<SourceElement>, SourceReadError> {
        let mut elements = Vec::new();
        let mut constraints = false;
        loop {
            let start = self.peek().ok_or(SourceReadError::Unterminated)?.range.start;
            let kind = if self.at_any(TABLE_CONSTRAINT_STARTS) {
                constraints = true;
                ElementKind::Constraint(self.table_constraint()?)
            } else if constraints {
                return Err(self.unexpected());
            } else {
                ElementKind::Column(self.column()?)
            };
            elements.push(SourceElement {
                range: start..self.last_end(),
                kind,
            });
            if self.at_punct(",") {
                self.position += 1;
            } else if self.at_kind(ScriptTokenKind::CloseParen) {
                return Ok(elements);
            } else if !(constraints && self.at_any(TABLE_CONSTRAINT_STARTS)) {
                return Err(self.unexpected());
            }
        }
    }

    fn close(&mut self) -> Result<usize, SourceReadError> {
        match self.peek() {
            Some(token) if token.kind == ScriptTokenKind::CloseParen => {
                let close = token.range.start;
                self.position += 1;
                Ok(close)
            }
            _ => Err(self.unexpected()),
        }
    }

    /// `WITHOUT ROWID` and `STRICT`, comma separated, up to the end or a
    /// closing semicolon.
    fn options(&mut self) -> Result<(Range<usize>, bool), SourceReadError> {
        let start = self.last_end();
        let mut end = start;
        let mut without_rowid = false;
        while let Some(token) = self.peek().cloned() {
            match token.kind {
                ScriptTokenKind::Semicolon => {
                    self.position += 1;
                    return match self.peek() {
                        Some(_) => Err(self.unexpected()),
                        None => Ok((start..end, without_rowid)),
                    };
                }
                ScriptTokenKind::Word => {
                    without_rowid |= self.at("WITHOUT") && self.is_word(1, "ROWID");
                }
                _ if self.at_punct(",") => {}
                _ => return Err(self.unexpected()),
            }
            end = token.range.end;
            self.position += 1;
        }
        Ok((start..end, without_rowid))
    }

    fn column(&mut self) -> Result<SourceColumn, SourceReadError> {
        let (name, name_range) = self.name()?;
        let type_range = self.type_name()?;
        let segments = self.column_constraints()?;
        Ok(SourceColumn {
            name,
            name_range,
            type_range,
            segments,
        })
    }

    fn at_column_constraint(&self) -> bool {
        self.at_any(COLUMN_CONSTRAINT_STARTS) || (self.at("GENERATED") && self.is_word(1, "ALWAYS"))
    }

    /// The type: names up to the first constraint, then at most one
    /// parenthesised size.
    fn type_name(&mut self) -> Result<Option<Range<usize>>, SourceReadError> {
        let first = self.position;
        while let Some(token) = self.peek() {
            match token.kind {
                ScriptTokenKind::Word if self.at_column_constraint() => break,
                ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::StringLiteral => {
                    self.position += 1;
                }
                ScriptTokenKind::OpenParen if self.position > first => {
                    self.group()?;
                    break;
                }
                _ => break,
            }
        }
        Ok(self
            .tokens
            .get(first)
            .filter(|_| self.position > first)
            .map(|token| token.range.start..self.last_end()))
    }

    fn column_constraints(&mut self) -> Result<Vec<ColumnConstraintSegment>, SourceReadError> {
        let mut segments = Vec::new();
        loop {
            let Some(token) = self.peek() else {
                return Err(SourceReadError::Unterminated);
            };
            if token.kind == ScriptTokenKind::CloseParen || self.at_punct(",") {
                return Ok(segments);
            }
            let start = token.range.start;
            let kind = self.column_constraint()?;
            segments.push(ColumnConstraintSegment {
                range: start..self.last_end(),
                kind,
            });
        }
    }

    fn column_constraint(&mut self) -> Result<ColumnConstraintKind, SourceReadError> {
        if self.eat("CONSTRAINT") {
            return Ok(ColumnConstraintKind::Name(self.name()?.0));
        }
        if self.eat("PRIMARY") {
            self.expect("KEY")?;
            let descending = self.at("DESC");
            self.eat_any(&["ASC", "DESC"]);
            self.conflict()?;
            let autoincrement = self.eat("AUTOINCREMENT");
            return Ok(ColumnConstraintKind::PrimaryKey {
                autoincrement,
                descending,
            });
        }
        // NOT NULL and NOT DEFERRABLE share their first word.
        if self.at("NOT") && self.is_word(1, "NULL") {
            self.position += 2;
            self.conflict()?;
            return Ok(ColumnConstraintKind::NotNull);
        }
        if self.at("DEFERRABLE") || (self.at("NOT") && self.is_word(1, "DEFERRABLE")) {
            self.deferrable()?;
            return Ok(ColumnConstraintKind::Deferrable);
        }
        if self.eat("NULL") {
            self.conflict()?;
            return Ok(ColumnConstraintKind::Null);
        }
        if self.eat("UNIQUE") {
            self.conflict()?;
            return Ok(ColumnConstraintKind::Unique);
        }
        if self.eat("CHECK") {
            self.group()?;
            return Ok(ColumnConstraintKind::Check);
        }
        if self.eat("DEFAULT") {
            self.default_value()?;
            return Ok(ColumnConstraintKind::Default);
        }
        if self.eat("COLLATE") {
            self.name()?;
            return Ok(ColumnConstraintKind::Collate);
        }
        if self.eat("REFERENCES") {
            return Ok(ColumnConstraintKind::References(self.references()?));
        }
        if self.eat("GENERATED") {
            self.expect("ALWAYS")?;
            self.expect("AS")?;
            self.generated()?;
            return Ok(ColumnConstraintKind::Generated);
        }
        if self.eat("AS") {
            self.generated()?;
            return Ok(ColumnConstraintKind::Generated);
        }
        Err(self.unexpected())
    }

    /// `ON CONFLICT resolution`, where one is allowed.
    fn conflict(&mut self) -> Result<(), SourceReadError> {
        if self.at("ON") && self.is_word(1, "CONFLICT") {
            self.position += 2;
            if !self.eat_any(&["ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE"]) {
                return Err(self.unexpected());
            }
        }
        Ok(())
    }

    /// One item: a parenthesised expression, a signed number, a literal
    /// or a name. `DEFAULT NULL NOT NULL` is a NULL default on a NOT NULL
    /// column.
    fn default_value(&mut self) -> Result<(), SourceReadError> {
        if self.at_kind(ScriptTokenKind::OpenParen) {
            self.group()?;
            return Ok(());
        }
        if self.at_punct("+") || self.at_punct("-") {
            self.position += 1;
        }
        match self.peek().map(|token| token.kind) {
            Some(
                ScriptTokenKind::Number
                | ScriptTokenKind::StringLiteral
                | ScriptTokenKind::Word
                | ScriptTokenKind::QuotedIdentifier,
            ) => {
                self.position += 1;
                Ok(())
            }
            _ => Err(self.unexpected()),
        }
    }

    /// The parenthesised expression and the storage after it. SQLite's
    /// grammar takes any name there and checks it later.
    fn generated(&mut self) -> Result<(), SourceReadError> {
        self.group()?;
        self.eat_any(&["STORED", "VIRTUAL"]);
        Ok(())
    }

    /// What follows REFERENCES: the parent, its columns, the actions,
    /// MATCH, and whether the check is deferred.
    fn references(&mut self) -> Result<ForeignKeyTarget, SourceReadError> {
        let (table, _) = self.name()?;
        let columns = match self.at_kind(ScriptTokenKind::OpenParen) {
            true => self.name_list()?,
            false => Vec::new(),
        };
        loop {
            if self.at("ON") && !self.is_word(1, "CONFLICT") {
                self.position += 1;
                if !self.eat_any(&["DELETE", "UPDATE", "INSERT"]) {
                    return Err(self.unexpected());
                }
                self.action()?;
            } else if self.eat("MATCH") {
                self.name()?;
            } else {
                break;
            }
        }
        if self.at("DEFERRABLE") || (self.at("NOT") && self.is_word(1, "DEFERRABLE")) {
            self.deferrable()?;
        }
        Ok(ForeignKeyTarget { table, columns })
    }

    fn action(&mut self) -> Result<(), SourceReadError> {
        let known = if self.eat("SET") {
            self.eat_any(&["NULL", "DEFAULT"])
        } else if self.eat("NO") {
            self.eat("ACTION")
        } else {
            self.eat_any(&["CASCADE", "RESTRICT"])
        };
        match known {
            true => Ok(()),
            false => Err(self.unexpected()),
        }
    }

    fn deferrable(&mut self) -> Result<(), SourceReadError> {
        self.eat("NOT");
        self.expect("DEFERRABLE")?;
        if self.eat("INITIALLY") && !self.eat_any(&["DEFERRED", "IMMEDIATE"]) {
            return Err(self.unexpected());
        }
        Ok(())
    }

    fn table_constraint(&mut self) -> Result<TableConstraint, SourceReadError> {
        let name = match self.eat("CONSTRAINT") {
            true => Some(self.name()?.0),
            false => None,
        };
        let kind = if self.eat("PRIMARY") {
            self.expect("KEY")?;
            let start = self.position;
            let columns = self.name_list()?;
            let autoincrement = self
                .tokens
                .get(start..self.position)
                .unwrap_or_default()
                .iter()
                .any(|token| {
                    token.kind == ScriptTokenKind::Word && self.text_of(token).eq_ignore_ascii_case("AUTOINCREMENT")
                });
            self.conflict()?;
            TableConstraintKind::PrimaryKey { columns, autoincrement }
        } else if self.eat("UNIQUE") {
            let columns = self.name_list()?;
            self.conflict()?;
            TableConstraintKind::Unique { columns }
        } else if self.eat("CHECK") {
            self.group()?;
            self.conflict()?;
            TableConstraintKind::Check
        } else if self.eat("FOREIGN") {
            self.expect("KEY")?;
            let columns = self.name_list()?;
            self.expect("REFERENCES")?;
            let target = self.references()?;
            TableConstraintKind::ForeignKey { columns, target }
        } else if name.is_some() {
            TableConstraintKind::NameOnly
        } else {
            return Err(self.unexpected());
        };
        Ok(TableConstraint { name, kind })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(sql: &str) -> CreateTableSource<'_> {
        CreateTableSource::read(sql).unwrap_or_else(|error| panic!("{sql}: {error}"))
    }

    fn column<'s>(source: &'s CreateTableSource<'_>, name: &str) -> &'s SourceColumn {
        source
            .columns()
            .map(|(_, column)| column)
            .find(|column| column.name == name)
            .unwrap_or_else(|| panic!("no column {name}"))
    }

    fn kinds(column: &SourceColumn) -> Vec<&ColumnConstraintKind> {
        column.segments.iter().map(|segment| &segment.kind).collect()
    }

    fn segment_texts<'s>(source: &CreateTableSource<'s>, column: &SourceColumn) -> Vec<&'s str> {
        column
            .segments
            .iter()
            .map(|segment| source.text(segment.range.clone()))
            .collect()
    }

    fn type_text<'s>(source: &CreateTableSource<'s>, column: &SourceColumn) -> Option<&'s str> {
        column.type_range.clone().map(|range| source.text(range))
    }

    #[test]
    fn identifiers_in_every_quote_style_read_as_their_names() {
        let source = read("CREATE TABLE \"we\"\"ird\" (\"a\"\"b\" TEXT, `c``d` INT, [e f] REAL, 'g' BLOB, plain)");

        assert_eq!(source.table, "we\"ird");
        let names: Vec<&str> = source.columns().map(|(_, column)| column.name.as_str()).collect();
        assert_eq!(names, ["a\"b", "c`d", "e f", "g", "plain"]);
        assert_eq!(type_text(&source, column(&source, "e f")), Some("REAL"));
        assert_eq!(column(&source, "plain").type_range, None);
    }

    #[test]
    fn a_multibyte_identifier_keeps_its_byte_ranges() {
        let sql = "CREATE TABLE café (naïve TEXT NOT NULL, \"日本\" VARCHAR(10) DEFAULT 'é')";
        let source = read(sql);

        let naive = column(&source, "naïve");
        assert_eq!(source.text(naive.name_range.clone()), "naïve");
        assert_eq!(segment_texts(&source, naive), ["NOT NULL"]);
        let japanese = column(&source, "日本");
        assert_eq!(type_text(&source, japanese), Some("VARCHAR(10)"));
        assert_eq!(segment_texts(&source, japanese), ["DEFAULT 'é'"]);
        assert_eq!(
            source.text(source.elements[1].range.clone()),
            "\"日本\" VARCHAR(10) DEFAULT 'é'"
        );
    }

    #[test]
    fn default_null_is_one_item_before_not_null() {
        let source =
            read("CREATE TABLE t (a TEXT DEFAULT NULL NOT NULL, b INT DEFAULT -1 NULL, c DEFAULT x'0A' UNIQUE)");

        assert_eq!(
            segment_texts(&source, column(&source, "a")),
            ["DEFAULT NULL", "NOT NULL"]
        );
        assert_eq!(
            kinds(column(&source, "b")),
            [&ColumnConstraintKind::Default, &ColumnConstraintKind::Null]
        );
        assert_eq!(
            segment_texts(&source, column(&source, "c")),
            ["DEFAULT x'0A'", "UNIQUE"]
        );
        assert_eq!(column(&source, "c").type_range, None);
    }

    #[test]
    fn not_deferrable_is_part_of_the_foreign_key_and_not_null_is_not() {
        let source = read(
            "CREATE TABLE t (a INT REFERENCES p (id) ON DELETE SET NULL MATCH SIMPLE NOT DEFERRABLE INITIALLY \
             IMMEDIATE NOT NULL, b INT REFERENCES q DEFERRABLE INITIALLY DEFERRED)",
        );

        let a = column(&source, "a");
        assert_eq!(
            segment_texts(&source, a),
            [
                "REFERENCES p (id) ON DELETE SET NULL MATCH SIMPLE NOT DEFERRABLE INITIALLY IMMEDIATE",
                "NOT NULL"
            ]
        );
        assert_eq!(
            kinds(a)[0],
            &ColumnConstraintKind::References(ForeignKeyTarget {
                table: "p".to_owned(),
                columns: vec!["id".to_owned()],
            })
        );
        assert_eq!(
            kinds(column(&source, "b")),
            [&ColumnConstraintKind::References(ForeignKeyTarget {
                table: "q".to_owned(),
                columns: Vec::new(),
            })]
        );
    }

    #[test]
    fn conflict_clauses_stay_with_their_constraint() {
        let source = read(
            "CREATE TABLE t (id INTEGER PRIMARY KEY DESC ON CONFLICT REPLACE AUTOINCREMENT, a TEXT NOT NULL ON \
             CONFLICT IGNORE UNIQUE ON CONFLICT FAIL, CONSTRAINT k UNIQUE (a) ON CONFLICT ABORT)",
        );

        assert_eq!(
            kinds(column(&source, "id")),
            [&ColumnConstraintKind::PrimaryKey {
                autoincrement: true,
                descending: true
            }]
        );
        assert_eq!(
            segment_texts(&source, column(&source, "a")),
            ["NOT NULL ON CONFLICT IGNORE", "UNIQUE ON CONFLICT FAIL"]
        );
        assert_eq!(source.autoincrement_column(), Some("id"));
        let constraints: Vec<&TableConstraint> = source.constraints().map(|(_, constraint)| constraint).collect();
        assert_eq!(
            constraints,
            [&TableConstraint {
                name: Some("k".to_owned()),
                kind: TableConstraintKind::Unique {
                    columns: vec!["a".to_owned()]
                },
            }]
        );
    }

    #[test]
    fn inline_and_table_foreign_keys_come_in_declaration_order() {
        let source = read(
            "CREATE TABLE c (a INTEGER CONSTRAINT to_p REFERENCES p, b TEXT, CONSTRAINT second FOREIGN KEY (b) \
             REFERENCES q (k) ON DELETE CASCADE ON UPDATE NO ACTION MATCH FULL DEFERRABLE, FOREIGN KEY (a, b) \
             REFERENCES z)",
        );

        let keys = source.foreign_keys();
        let summary: Vec<String> = keys
            .iter()
            .map(|key| {
                format!(
                    "{:?} {} -> {} at {} {:?}",
                    key.name,
                    key.columns.join(","),
                    key.target.table,
                    key.element,
                    key.segment
                )
            })
            .collect();
        assert_eq!(
            summary,
            [
                "Some(\"to_p\") a -> p at 0 Some(1)",
                "Some(\"second\") b -> q at 2 None",
                "None a,b -> z at 3 None",
            ]
        );
        assert_eq!(
            declared_foreign_key_names(source.sql()),
            Some(vec![None, Some("second".to_owned()), Some("to_p".to_owned())])
        );
        assert_eq!(
            kinds(column(&source, "a")),
            [
                &ColumnConstraintKind::Name("to_p".to_owned()),
                &ColumnConstraintKind::References(ForeignKeyTarget {
                    table: "p".to_owned(),
                    columns: Vec::new()
                })
            ]
        );
    }

    #[test]
    fn nested_check_and_stored_generated_column_read_whole() {
        let source = read(
            "CREATE TABLE t (a INT CHECK (a > (SELECT 0) AND a <> ')'), b INT GENERATED ALWAYS AS (a * (2 + 1)) \
             STORED NOT NULL, c AS (a || 'x') VIRTUAL, CHECK (b > a))",
        );

        assert_eq!(
            segment_texts(&source, column(&source, "a")),
            ["CHECK (a > (SELECT 0) AND a <> ')')"]
        );
        assert_eq!(
            segment_texts(&source, column(&source, "b")),
            ["GENERATED ALWAYS AS (a * (2 + 1)) STORED", "NOT NULL"]
        );
        assert_eq!(segment_texts(&source, column(&source, "c")), ["AS (a || 'x') VIRTUAL"]);
        let (index, constraint) = source.constraints().next().unwrap();
        assert_eq!(constraint.kind, TableConstraintKind::Check);
        assert_eq!(source.text(source.elements[index].range.clone()), "CHECK (b > a)");
    }

    #[test]
    fn comments_stay_outside_the_elements_they_follow() {
        let sql =
            "CREATE TABLE t ( -- the key\n  id INTEGER /* inline */ PRIMARY KEY, -- trailing\n  name TEXT -- last\n)";
        let source = read(sql);

        let texts: Vec<&str> = source
            .elements
            .iter()
            .map(|element| source.text(element.range.clone()))
            .collect();
        assert_eq!(texts, ["id INTEGER /* inline */ PRIMARY KEY", "name TEXT"]);
        assert_eq!(source.text(source.close..source.close + 1), ")");
        assert!(!source.mentions(source.elements[0].range.clone()).contains("inline"));
    }

    #[test]
    fn without_rowid_and_strict_options_are_kept() {
        let source = read("CREATE TABLE t (k TEXT PRIMARY KEY, v ANY) WITHOUT ROWID, STRICT");
        let plain = read("CREATE TABLE t (k TEXT PRIMARY KEY) STRICT;");

        assert!(source.without_rowid);
        assert_eq!(source.text(source.options.clone()), " WITHOUT ROWID, STRICT");
        assert!(!plain.without_rowid);
        assert_eq!(plain.text(plain.options.clone()), " STRICT");
    }

    #[test]
    fn table_constraints_may_follow_one_another_without_commas() {
        let source = read(
            "CREATE TABLE t2(a INTEGER, b, UNIQUE(a) CHECK(a > 0) PRIMARY KEY (a COLLATE nocase DESC, b AUTOINCREMENT))",
        );

        let kinds: Vec<&TableConstraintKind> = source.constraints().map(|(_, constraint)| &constraint.kind).collect();
        assert_eq!(
            kinds,
            [
                &TableConstraintKind::Unique {
                    columns: vec!["a".to_owned()]
                },
                &TableConstraintKind::Check,
                &TableConstraintKind::PrimaryKey {
                    columns: vec!["a".to_owned(), "b".to_owned()],
                    autoincrement: true
                },
            ]
        );
        assert_eq!(source.autoincrement_column(), None);
    }

    #[test]
    fn a_type_of_several_words_ends_at_the_first_constraint() {
        let source =
            read("CREATE TABLE t (a UNSIGNED BIG INT NOT NULL, b DOUBLE PRECISION, c DECIMAL(10, 5) COLLATE BINARY)");

        assert_eq!(type_text(&source, column(&source, "a")), Some("UNSIGNED BIG INT"));
        assert_eq!(type_text(&source, column(&source, "b")), Some("DOUBLE PRECISION"));
        assert_eq!(type_text(&source, column(&source, "c")), Some("DECIMAL(10, 5)"));
        assert_eq!(segment_texts(&source, column(&source, "c")), ["COLLATE BINARY"]);
    }

    #[test]
    fn a_column_added_by_alter_table_reads_before_the_table_constraints() {
        let source = read("CREATE TABLE \"p\" (\n  \"id\" INTEGER NOT NULL, \"note\" TEXT,\n  PRIMARY KEY (\"id\")\n)");

        let names: Vec<&str> = source.columns().map(|(_, column)| column.name.as_str()).collect();
        assert_eq!(names, ["id", "note"]);
        assert_eq!(source.constraints().count(), 1);
    }

    #[test]
    fn what_is_not_a_readable_create_table_is_refused() {
        let cases = [
            "CREATE VIRTUAL TABLE f USING fts5(body)",
            "CREATE TABLE t AS SELECT 1",
            "CREATE TABLE t (a TEXT",
            "CREATE TABLE t (a TEXT DEFAULT 'open)",
            "CREATE TABLE t (PRIMARY KEY (a), a TEXT)",
            "CREATE TABLE t (a TEXT) WITHOUT ROWID; SELECT 1",
            "CREATE INDEX i ON t (a)",
        ];

        for sql in cases {
            assert!(CreateTableSource::read(sql).is_err(), "{sql}");
        }
    }

    #[test]
    fn mentions_skip_strings_and_unquote_names() {
        let source = read("CREATE TABLE t (a INT CHECK (\"B\" > 0 AND a <> 'c'))");

        let mentions = source.mentions(source.elements[0].range.clone());
        assert!(mentions.contains("b") && mentions.contains("a"));
        assert!(!mentions.contains("c"));
    }
}
