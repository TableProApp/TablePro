use serde::de::Deserializer;
use serde::ser::{SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{MaskingStyle, MaskingTarget};

// One masking rule, stored as the macOS app stores it: `{id, pattern, target, style}` with an upper-case UUID.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MaskingRule {
    pub id: Uuid,
    pub pattern: String,
    pub target: MaskingTarget,
    pub style: MaskingStyle,
}

impl MaskingRule {
    pub fn new(pattern: impl Into<String>, target: MaskingTarget, style: MaskingStyle) -> Self {
        Self {
            id: Uuid::new_v4(),
            pattern: pattern.into(),
            target,
            style,
        }
    }

    // What a rule this build cannot read in full becomes, so a style, target or field a newer build added never
    // shows a value it meant to hide.
    pub fn mask_everything() -> Self {
        Self::new("*", MaskingTarget::Column, MaskingStyle::Full)
    }

    pub fn trimmed_pattern(&self) -> &str {
        self.pattern.trim()
    }
}

// A rule as the JSON holds it. A field of the wrong JSON type fails the whole list, as Swift's decoder does.
#[derive(Deserialize)]
struct StoredRule {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    pattern: Option<String>,
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    style: Option<String>,
}

impl StoredRule {
    fn rule(self) -> Option<MaskingRule> {
        let id = match self.id {
            Some(text) => swift_uuid(&text)?,
            None => Uuid::new_v4(),
        };
        let target = match self.target.as_deref().map(MaskingTarget::from_code) {
            None => MaskingTarget::Column,
            Some(Some(target)) => target,
            Some(None) => {
                return Some(MaskingRule {
                    id,
                    ..MaskingRule::mask_everything()
                });
            }
        };
        let Some(pattern) = self.pattern else {
            return Some(MaskingRule {
                id,
                ..MaskingRule::mask_everything()
            });
        };
        Some(MaskingRule {
            id,
            pattern,
            target,
            style: self
                .style
                .as_deref()
                .and_then(MaskingStyle::from_code)
                .unwrap_or(MaskingStyle::Full),
        })
    }
}

// Foundation reads a UUID only in its 36-character hyphenated form.
fn swift_uuid(text: &str) -> Option<Uuid> {
    (text.len() == 36).then(|| Uuid::try_parse(text).ok()).flatten()
}

// The rules a stored list holds. A list nothing can read masks everything, so a damaged file never shows a value.
pub fn decode_rules(json: &str) -> Vec<MaskingRule> {
    if json.trim().is_empty() {
        return Vec::new();
    }
    match serde_json::from_str::<serde_json::Value>(json) {
        Ok(value) => decode_rules_value(value),
        Err(_) => vec![MaskingRule::mask_everything()],
    }
}

// As `decode_rules`, from a value already parsed. A string holds the list's JSON, as the macOS app's additional
// fields keep it; null is no rules.
pub fn decode_rules_value(value: serde_json::Value) -> Vec<MaskingRule> {
    match value {
        serde_json::Value::Null => Vec::new(),
        serde_json::Value::String(json) => decode_rules(&json),
        value => serde_json::from_value::<Vec<StoredRule>>(value)
            .ok()
            .and_then(|stored| stored.into_iter().map(StoredRule::rule).collect())
            .unwrap_or_else(|| vec![MaskingRule::mask_everything()]),
    }
}

// The list as the macOS app writes it, without rules whose pattern is blank; None when no rule is left.
pub fn encode_rules(rules: &[MaskingRule]) -> Option<String> {
    let kept: Vec<&MaskingRule> = rules.iter().filter(|rule| !rule.trimmed_pattern().is_empty()).collect();
    match kept.is_empty() {
        true => None,
        false => serde_json::to_string(&kept).ok(),
    }
}

// For a stored field: any JSON reads as rules, never as an error that would drop the whole document.
pub fn deserialize_rules<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<MaskingRule>, D::Error> {
    Ok(decode_rules_value(serde_json::Value::deserialize(deserializer)?))
}

impl Serialize for MaskingRule {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut rule = serializer.serialize_struct("MaskingRule", 4)?;
        let mut id = Uuid::encode_buffer();
        rule.serialize_field("id", self.id.hyphenated().encode_upper(&mut id))?;
        rule.serialize_field("pattern", &self.pattern)?;
        rule.serialize_field("target", self.target.code())?;
        rule.serialize_field("style", self.style.code())?;
        rule.end()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0E0B2B8A-5B7C-4E36-9F6E-2D1F0C3A4B5C";

    fn decoded(json: &str) -> Vec<(String, MaskingTarget, MaskingStyle)> {
        decode_rules(json)
            .into_iter()
            .map(|rule| (rule.pattern, rule.target, rule.style))
            .collect()
    }

    fn everything() -> (String, MaskingTarget, MaskingStyle) {
        ("*".to_owned(), MaskingTarget::Column, MaskingStyle::Full)
    }

    #[test]
    fn a_macos_list_reads_with_its_ids_targets_and_styles() {
        let json = format!(
            r#"[{{"style":"lastFour","id":"{ID}","target":"column","pattern":"users.phone"}},
               {{"id":"{}","pattern":"uuid","target":"type","style":"hash"}}]"#,
            ID.to_lowercase()
        );

        let rules = decode_rules(&json);

        assert_eq!(rules[0].id.to_string().to_uppercase(), ID);
        assert_eq!(
            decoded(&json),
            [
                ("users.phone".to_owned(), MaskingTarget::Column, MaskingStyle::LastFour),
                ("uuid".to_owned(), MaskingTarget::Type, MaskingStyle::Hash),
            ]
        );
    }

    #[test]
    fn missing_fields_take_the_defaults_and_an_unknown_target_masks_everything() {
        assert_eq!(
            decoded(r#"[{"pattern":"email"}]"#),
            [("email".to_owned(), MaskingTarget::Column, MaskingStyle::Full)]
        );
        assert_eq!(
            decoded(r#"[{"pattern":"email","style":"rainbow","target":null}]"#),
            [("email".to_owned(), MaskingTarget::Column, MaskingStyle::Full)]
        );
        assert_eq!(
            decoded(r#"[{"pattern":"email","target":"schema","style":"hash"}]"#),
            [everything()]
        );
        assert_eq!(decoded(r#"[{"target":"type","style":"hash"}]"#), [everything()]);
        assert_eq!(decoded(r#"[{"pattern":null,"style":"email"}]"#), [everything()]);
    }

    #[test]
    fn a_list_nothing_can_read_masks_everything() {
        for json in [
            "{",
            r#"{"pattern":"email"}"#,
            "[1]",
            r#"[{"pattern":5}]"#,
            r#"[{"pattern":"email","style":7}]"#,
            r#"[{"pattern":"email","id":"not-a-uuid"}]"#,
            r#"[{"pattern":"email","id":"0e0b2b8a5b7c4e369f6e2d1f0c3a4b5c"}]"#,
            r#"[{"pattern":"a"},{"pattern":"b","target":3}]"#,
        ] {
            assert_eq!(decoded(json), [everything()], "{json}");
        }
    }

    #[test]
    fn nothing_stored_is_no_rule() {
        assert!(decode_rules("").is_empty());
        assert!(decode_rules("  \n").is_empty());
        assert!(decode_rules("[]").is_empty());
        assert!(decode_rules_value(serde_json::Value::Null).is_empty());
    }

    #[test]
    fn a_list_kept_as_a_string_reads_as_the_list() {
        let value = serde_json::Value::String(r#"[{"pattern":"ssn","style":"lastFour"}]"#.to_owned());

        let rules = decode_rules_value(value);

        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].style, MaskingStyle::LastFour);
    }

    #[test]
    fn a_list_writes_as_the_macos_app_writes_it_without_blank_patterns() {
        let mut kept = MaskingRule::new("*.email", MaskingTarget::Column, MaskingStyle::Email);
        kept.id = Uuid::try_parse(ID).expect("a UUID");
        let blank = MaskingRule::new(" \n", MaskingTarget::Type, MaskingStyle::Hash);

        let json = encode_rules(&[kept.clone(), blank.clone()]).expect("a rule is kept");

        assert_eq!(
            json,
            format!(r#"[{{"id":"{ID}","pattern":"*.email","target":"column","style":"email"}}]"#)
        );
        assert_eq!(decode_rules(&json), [kept]);
        assert_eq!(encode_rules(&[blank]), None);
    }
}
