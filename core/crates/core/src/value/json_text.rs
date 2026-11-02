use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct JsonText {
    text: Box<str>,
}

/// Where serde_json stopped reading. Its message is English only, so
/// the position is kept instead, for the app to point at.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum JsonTextError {
    #[error("the JSON ends before its value does")]
    Incomplete,
    #[error("invalid JSON at line {line}, column {column}")]
    Invalid { line: usize, column: usize },
}

impl JsonTextError {
    fn from_serde(error: &serde_json::Error) -> Self {
        match error.classify() {
            serde_json::error::Category::Eof => Self::Incomplete,
            _ => Self::Invalid {
                line: error.line(),
                column: error.column(),
            },
        }
    }
}

impl JsonText {
    pub fn parse(text: String) -> Result<Self, JsonTextError> {
        serde_json::from_str::<serde::de::IgnoredAny>(&text).map_err(|error| JsonTextError::from_serde(&error))?;
        Ok(Self {
            text: text.into_boxed_str(),
        })
    }

    pub fn as_str(&self) -> &str {
        &self.text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_text_rejects_trailing_garbage() {
        assert!(JsonText::parse(r#"{"a": 1} x"#.to_owned()).is_err());
        assert!(JsonText::parse(String::new()).is_err());
        let document = r#"{"price": 12.3400000000000000001, "tags": ["a"]}"#;
        assert_eq!(JsonText::parse(document.to_owned()).unwrap().as_str(), document);
    }

    #[test]
    fn a_refusal_says_where_the_json_went_wrong() {
        assert_eq!(JsonText::parse("{\"a\": 1".to_owned()), Err(JsonTextError::Incomplete));
        assert_eq!(JsonText::parse(String::new()), Err(JsonTextError::Incomplete));
        assert!(
            matches!(
                JsonText::parse("[1,\n2,\n3 4]".to_owned()),
                Err(JsonTextError::Invalid { line: 3, .. })
            ),
            "a missing comma on the third line"
        );
    }
}
