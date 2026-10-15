//! build.rs includes this file too, so the release it fills into the
//! metainfo's URLs and the one the tests expect are read the same way.

/// AppStream lists releases newest first, so this is the first
/// `<release>` element's version, whatever order its attributes are in.
pub(crate) fn newest_release(xml: &str) -> Option<&str> {
    let tag = xml
        .match_indices("<release")
        .map(|(start, open)| &xml[start + open.len()..])
        .find(|rest| rest.starts_with(|c: char| c.is_ascii_whitespace() || c == '>' || c == '/'))?;
    attribute(&tag[..tag.find('>')?], "version")
}

fn attribute<'a>(attributes: &'a str, name: &str) -> Option<&'a str> {
    let mut rest = attributes;
    loop {
        let (key, value) = rest.split_once('=')?;
        let value = value.trim_start();
        let quote = value.chars().next().filter(|c| matches!(c, '"' | '\''))?;
        let value = &value[1..];
        let end = value.find(quote)?;
        if key.trim() == name {
            return Some(&value[..end]);
        }
        rest = &value[end + 1..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_release_is_the_newest() {
        let xml = r#"<releases>
    <release version="1.1.0" date="2026-02-01"/>
    <release version="1.0.0" date="2026-01-01"/>
  </releases>"#;

        assert_eq!(newest_release(xml), Some("1.1.0"));
    }

    #[test]
    fn the_version_can_come_after_other_attributes() {
        assert_eq!(
            newest_release(r#"<release date="2026-01-01" version="1.0.0">"#),
            Some("1.0.0")
        );
        assert_eq!(
            newest_release("<release\n  type='stable' urgency='low'\n  version = '1.0.0'>"),
            Some("1.0.0")
        );
        assert_eq!(
            newest_release(r#"<release subversion="2" version="1.0.0">"#),
            Some("1.0.0")
        );
    }

    #[test]
    fn a_release_without_a_version_names_none() {
        assert_eq!(newest_release("<releases></releases>"), None);
        assert_eq!(newest_release(r#"<release date="2026-01-01">"#), None);
        assert_eq!(
            newest_release(r#"<release date="2026-01-01"/><release version="1.0.0"/>"#),
            None,
            "an older release stood in for the newest"
        );
    }
}
