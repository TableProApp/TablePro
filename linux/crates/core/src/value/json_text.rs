use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct JsonText {
    text: Box<str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum JsonTextError {
    #[error("invalid JSON: {0}")]
    Invalid(String),
}

impl JsonText {
    pub fn parse(text: String) -> Result<Self, JsonTextError> {
        serde_json::from_str::<serde::de::IgnoredAny>(&text)
            .map_err(|error| JsonTextError::Invalid(error.to_string()))?;
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
}
