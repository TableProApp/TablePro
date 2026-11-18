use url::Url;

// tablepro-cloud mints 32 random bytes as 43 base62 characters, and its validation takes exactly that.
const TOKEN_LENGTH: usize = 43;

pub fn is_share_token(token: &str) -> bool {
    token.len() == TOKEN_LENGTH && token.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

// The token of `tablepro://share?token=<token>`, the deep link a viewer page opens the app with.
pub fn share_token_from_link(link: &str) -> Option<String> {
    let url = Url::parse(link.trim()).ok()?;
    if url.scheme() != "tablepro" || url.host_str() != Some("share") || !matches!(url.path(), "" | "/") {
        return None;
    }
    let mut tokens = url.query_pairs().filter(|(name, _)| name == "token");
    let token = tokens.next()?.1.into_owned();
    (tokens.next().is_none() && is_share_token(&token)).then_some(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";

    #[test]
    fn a_token_is_43_base62_characters() {
        assert_eq!(TOKEN.len(), 43);
        assert!(is_share_token(TOKEN));
        for token in [
            "",
            &TOKEN[..42],
            &format!("{TOKEN}a"),
            &format!("{}-", &TOKEN[..42]),
            &format!("{}_", &TOKEN[..42]),
            &format!("{}é", &TOKEN[..41]),
        ] {
            assert!(!is_share_token(token), "{token:?}");
        }
    }

    #[test]
    fn the_deep_link_gives_its_token() {
        assert_eq!(
            share_token_from_link(&format!("tablepro://share?token={TOKEN}")).as_deref(),
            Some(TOKEN)
        );
        assert_eq!(
            share_token_from_link(&format!(" tablepro://share/?token={TOKEN}&from=viewer\n")).as_deref(),
            Some(TOKEN)
        );
    }

    #[test]
    fn any_other_link_gives_none() {
        for link in [
            format!("https://share?token={TOKEN}"),
            format!("tablepro://connect?token={TOKEN}"),
            format!("tablepro://share/open?token={TOKEN}"),
            "tablepro://share".to_owned(),
            "tablepro://share?token=short".to_owned(),
            format!("tablepro://share?token={TOKEN}&token={TOKEN}"),
            format!("https://s.tablepro.app/{TOKEN}"),
            TOKEN.to_owned(),
        ] {
            assert_eq!(share_token_from_link(&link), None, "{link}");
        }
    }
}
