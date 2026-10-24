use std::fmt::{self, Display, Formatter, Write};

use super::{CallRoot, ShellCall, ShellStatement, ShellValue, ShowTarget};

/// Shell text that reads back as the same value: keys and strings in
/// double quotes, helpers by their canonical names.
impl Display for ShellValue {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::Object(fields) => {
                f.write_char('{')?;
                for (index, (key, value)) in fields.iter().enumerate() {
                    if index > 0 {
                        f.write_str(", ")?;
                    }
                    write_string(f, key)?;
                    write!(f, ": {value}")?;
                }
                f.write_char('}')
            }
            Self::Array(items) => {
                f.write_char('[')?;
                write_list(f, items)?;
                f.write_char(']')
            }
            Self::String(text) => write_string(f, text),
            Self::Number(number) => f.write_str(number.text()),
            Self::Bool(value) => write!(f, "{value}"),
            Self::Null => f.write_str("null"),
            Self::Regex { pattern, flags } => write!(f, "/{pattern}/{flags}"),
            Self::Constructor { kind, args } => {
                write!(f, "{}(", kind.name())?;
                write_list(f, args)?;
                f.write_char(')')
            }
            Self::Param(index) => write!(f, "${index}"),
        }
    }
}

impl Display for ShellStatement {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::Show(target) => {
                let name = match target {
                    ShowTarget::Databases => "dbs",
                    ShowTarget::Collections => "collections",
                    ShowTarget::Users => "users",
                    ShowTarget::Roles => "roles",
                };
                write!(f, "show {name}")
            }
            Self::Use(database) => write!(f, "use {database}"),
            Self::Call(call) => write!(f, "{call}"),
        }
    }
}

impl Display for ShellCall {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str(match self.root {
            CallRoot::Db => "db",
            CallRoot::Rs => "rs",
        })?;
        if let Some(database) = &self.database {
            f.write_str(".getSiblingDB(")?;
            write_string(f, database)?;
            f.write_char(')')?;
        }
        if let Some(collection) = &self.collection {
            f.write_str(".getCollection(")?;
            write_string(f, collection)?;
            f.write_char(')')?;
        }
        for method in &self.methods {
            write!(f, ".{}(", method.name)?;
            write_list(f, &method.args)?;
            f.write_char(')')?;
        }
        Ok(())
    }
}

fn write_list(f: &mut Formatter<'_>, items: &[ShellValue]) -> fmt::Result {
    for (index, item) in items.iter().enumerate() {
        if index > 0 {
            f.write_str(", ")?;
        }
        write!(f, "{item}")?;
    }
    Ok(())
}

/// A JavaScript string literal: JSON's escapes, which JavaScript reads
/// the same way.
fn write_string(f: &mut Formatter<'_>, text: &str) -> fmt::Result {
    f.write_char('"')?;
    for c in text.chars() {
        match c {
            '"' => f.write_str("\\\"")?,
            '\\' => f.write_str("\\\\")?,
            '\n' => f.write_str("\\n")?,
            '\r' => f.write_str("\\r")?,
            '\t' => f.write_str("\\t")?,
            '\u{2028}' => f.write_str("\\u2028")?,
            '\u{2029}' => f.write_str("\\u2029")?,
            c if c.is_control() => write!(f, "\\u{:04x}", u32::from(c))?,
            c => f.write_char(c)?,
        }
    }
    f.write_char('"')
}

#[cfg(test)]
mod tests {
    use super::super::{ShellConstructor, ShellMethod, ShellNumber, parse_statement, parse_value};
    use super::*;

    #[test]
    fn a_value_prints_as_shell_text_that_reads_back_the_same() {
        let texts = [
            r#"{"_id": ObjectId("5f1d7a0c9b1e8b2a3c4d5e6f"), "tags": ["a", "b"], "n": -1.5}"#,
            r#"{"at": ISODate("2024-01-02T03:04:05Z"), "re": /^a\/b/i, "big": NumberLong("9007199254740993")}"#,
            r#"{"quote": "say \"hi\"\n\ttab", "nested": {"deep": [null, true, false]}}"#,
            r#"{"$or": [{"a": MinKey()}, {"b": Timestamp(1, 2)}]}"#,
        ];
        for text in texts {
            let value = parse_value(text).expect("a value");
            assert_eq!(value.to_string(), text);
            assert_eq!(parse_value(&value.to_string()), Ok(value));
        }
    }

    #[test]
    fn a_control_character_is_escaped() {
        assert_eq!(ShellValue::string("a\u{1}b").to_string(), r#""a\u0001b""#);
        assert_eq!(
            parse_value(&ShellValue::string("a\u{1}\u{2028}b").to_string()),
            Ok(ShellValue::string("a\u{1}\u{2028}b"))
        );
    }

    #[test]
    fn a_call_names_its_collection_with_get_collection() {
        let call = ShellCall {
            root: CallRoot::Db,
            database: None,
            collection: Some("order items".to_owned()),
            methods: vec![
                ShellMethod::new(
                    "find",
                    vec![ShellValue::object(vec![("qty".to_owned(), ShellValue::Param(1))])],
                ),
                ShellMethod::new("limit", vec![ShellValue::Number(ShellNumber::new("10"))]),
            ],
        };

        let text = call.to_string();

        assert_eq!(text, r#"db.getCollection("order items").find({"qty": $1}).limit(10)"#);
        assert!(parse_statement(&text).is_err(), "typed text took a parameter");
        assert_eq!(
            super::super::parse_bound_statement(&text, 1),
            Ok(ShellStatement::Call(call))
        );
        assert_eq!(
            ShellValue::Constructor {
                kind: ShellConstructor::MaxKey,
                args: Vec::new()
            }
            .to_string(),
            "MaxKey()"
        );
    }
}
