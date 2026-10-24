use tablepro_core::{ColumnInfo, EnumInputStyle, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnumInputError {
    InvalidMemberDeclaration,
    UndeclaredMember,
}

pub fn declared_member_labels(data_type: &str) -> Option<Vec<String>> {
    let open = data_type.find('(')?;
    let kind = data_type[..open].trim();
    if !kind.eq_ignore_ascii_case("enum") && !kind.eq_ignore_ascii_case("set") {
        return None;
    }
    parse_member_list(data_type)
}

pub fn parse_enum_input(
    text: &str,
    column: Option<&ColumnInfo>,
    style: EnumInputStyle,
) -> Option<Result<Value, EnumInputError>> {
    let column = column?;
    if text == "''" && column.enum_type.is_some() {
        return Some(Ok(Value::Text(String::new())));
    }
    match style {
        EnumInputStyle::RawValue => None,
        EnumInputStyle::DeclaredMemberList => parse_declared_member(text, column),
        EnumInputStyle::SqlQuotedLabel => parse_quoted_label(text, column),
    }
}

fn parse_declared_member(text: &str, column: &ColumnInfo) -> Option<Result<Value, EnumInputError>> {
    let data_type = column.data_type.trim();
    let Some(open) = data_type.find('(') else {
        let lower = data_type.to_ascii_lowercase();
        return (lower.starts_with("enum") || lower.starts_with("set"))
            .then_some(Err(EnumInputError::InvalidMemberDeclaration));
    };
    let kind = data_type[..open].trim();
    let is_enum = kind.eq_ignore_ascii_case("enum");
    let is_set = kind.eq_ignore_ascii_case("set");
    if !is_enum && !is_set {
        return (kind.to_ascii_lowercase().starts_with("enum") || kind.to_ascii_lowercase().starts_with("set"))
            .then_some(Err(EnumInputError::InvalidMemberDeclaration));
    }
    let Some(labels) = declared_member_labels(data_type) else {
        return Some(Err(EnumInputError::InvalidMemberDeclaration));
    };
    let value = if text == "''" { "" } else { text };
    let valid = if is_enum {
        labels.iter().any(|label| label == value)
    } else if value.is_empty() {
        true
    } else {
        value
            .split(',')
            .all(|member| labels.iter().any(|label| label == member))
    };
    Some(if valid {
        Ok(Value::Text(value.to_owned()))
    } else {
        Err(EnumInputError::UndeclaredMember)
    })
}

fn parse_member_list(data_type: &str) -> Option<Vec<String>> {
    let open = data_type.find('(')?;
    let mut chars = data_type[open + 1..].strip_suffix(')')?.chars().peekable();
    let mut labels = Vec::new();
    loop {
        while chars.peek().is_some_and(|ch| ch.is_whitespace()) {
            chars.next();
        }
        if chars.next()? != '\'' {
            return None;
        }
        let mut label = String::new();
        loop {
            match chars.next()? {
                '\\' => {
                    let escaped = chars.next()?;
                    label.push(match escaped {
                        '0' => '\0',
                        'b' => '\u{0008}',
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'Z' => '\u{001a}',
                        other => other,
                    });
                }
                '\'' if chars.peek() == Some(&'\'') => {
                    chars.next();
                    label.push('\'');
                }
                '\'' => break,
                ch => label.push(ch),
            }
        }
        labels.push(label);
        while chars.peek().is_some_and(|ch| ch.is_whitespace()) {
            chars.next();
        }
        match chars.next() {
            None => return Some(labels),
            Some(',') => {}
            Some(_) => return None,
        }
    }
}

fn parse_quoted_label(text: &str, column: &ColumnInfo) -> Option<Result<Value, EnumInputError>> {
    let data_type = column.data_type.trim().to_ascii_lowercase();
    let data_type = data_type.strip_prefix("nullable(").unwrap_or(&data_type);
    if !data_type.starts_with("enum") {
        return None;
    }
    parse_single_quoted(text.trim()).map(|label| Ok(Value::Text(label)))
}

fn parse_single_quoted(text: &str) -> Option<String> {
    if text.len() < 2 {
        return None;
    }
    let inner = text.strip_prefix('\'')?.strip_suffix('\'')?;
    let mut label = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\'' {
            label.push(ch);
            continue;
        }
        if chars.next()? != '\'' {
            return None;
        }
        label.push('\'');
    }
    Some(label)
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ColumnInfo, EnumInputStyle, QualifiedTypeName, Value};

    use super::{EnumInputError, parse_enum_input};

    fn column(data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: "state".into(),
            data_type: data_type.into(),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn declared_member_input_validates_mysql_enum_and_set_values() {
        let enum_column = column("enum('red','it\\'s blue','')");
        let set_column = column("set('read','write')");
        assert_eq!(
            parse_enum_input("it's blue", Some(&enum_column), EnumInputStyle::DeclaredMemberList),
            Some(Ok(Value::Text("it's blue".into())))
        );
        assert_eq!(
            parse_enum_input("read,write", Some(&set_column), EnumInputStyle::DeclaredMemberList),
            Some(Ok(Value::Text("read,write".into())))
        );
    }

    #[test]
    fn declared_member_input_refuses_unknown_values_and_malformed_declarations() {
        let enum_column = column("enum('red')");
        let malformed = column("enum('red'");
        let malformed_kind = column("enumx('red')");
        assert_eq!(
            parse_enum_input("blue", Some(&enum_column), EnumInputStyle::DeclaredMemberList),
            Some(Err(EnumInputError::UndeclaredMember))
        );
        assert_eq!(
            parse_enum_input("red", Some(&malformed), EnumInputStyle::DeclaredMemberList),
            Some(Err(EnumInputError::InvalidMemberDeclaration))
        );
        assert_eq!(
            parse_enum_input("red", Some(&malformed_kind), EnumInputStyle::DeclaredMemberList),
            Some(Err(EnumInputError::InvalidMemberDeclaration))
        );
    }

    #[test]
    fn quoted_label_input_unescapes_sql_labels_only_for_declared_enum_types() {
        let clickhouse_column = column("Nullable(Enum8('ready' = 1, 'it's ok' = 2))");
        let text_column = column("text");
        assert_eq!(
            parse_enum_input("'it''s ok'", Some(&clickhouse_column), EnumInputStyle::SqlQuotedLabel),
            Some(Ok(Value::Text("it's ok".into())))
        );
        assert_eq!(
            parse_enum_input("'it''s ok'", Some(&text_column), EnumInputStyle::SqlQuotedLabel),
            None
        );
    }

    #[test]
    fn column_enum_metadata_preserves_an_empty_member_as_text() {
        let mut pg_enum = column("USER-DEFINED");
        pg_enum.enum_type = Some(QualifiedTypeName {
            schema: "public".into(),
            name: "mood".into(),
        });
        assert_eq!(
            parse_enum_input("''", Some(&pg_enum), EnumInputStyle::RawValue),
            Some(Ok(Value::Text(String::new())))
        );
    }
}
