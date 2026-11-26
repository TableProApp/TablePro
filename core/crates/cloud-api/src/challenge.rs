use reqwest::header::{HeaderMap, WWW_AUTHENTICATE};

// RFC 9470 section 3: the error a resource server names when the token's authentication is too old or too weak.
const INSUFFICIENT_USER_AUTHENTICATION: &str = "insufficient_user_authentication";

// What a call that needs a fresh step-up asks the next authorization request for (RFC 9470 section 4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepUpChallenge {
    // In the server's order of preference.
    pub acr_values: Vec<String>,
    pub max_age_secs: Option<u64>,
}

impl StepUpChallenge {
    // The first Bearer or DPoP challenge naming RFC 9470's error across the answer's `WWW-Authenticate` fields. A field
    // that does not parse, or a challenge with a parameter twice or a `max_age` that is not whole seconds, asks for
    // nothing.
    pub fn from_headers(headers: &HeaderMap) -> Option<Self> {
        headers
            .get_all(WWW_AUTHENTICATE)
            .iter()
            .filter_map(|field| field.to_str().ok())
            .filter_map(challenges)
            .flatten()
            .filter(|challenge| {
                challenge.scheme.eq_ignore_ascii_case("bearer") || challenge.scheme.eq_ignore_ascii_case("dpop")
            })
            .find_map(|challenge| Self::from_params(&challenge.params))
    }

    fn from_params(params: &[(String, String)]) -> Option<Self> {
        let param = |name: &str| -> Result<Option<&str>, ()> {
            let mut named = params
                .iter()
                .filter(|(param, _)| param == name)
                .map(|(_, value)| value.as_str());
            let first = named.next();
            match named.next() {
                Some(_) => Err(()),
                None => Ok(first),
            }
        };
        if param("error").ok()?? != INSUFFICIENT_USER_AUTHENTICATION {
            return None;
        }
        let acr_values = param("acr_values")
            .ok()?
            .map(|values| {
                values
                    .split(' ')
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let max_age_secs = match param("max_age").ok()? {
            Some(seconds) if !seconds.is_empty() && seconds.bytes().all(|byte| byte.is_ascii_digit()) => {
                Some(seconds.parse().ok()?)
            }
            Some(_) => return None,
            None => None,
        };
        Some(Self {
            acr_values,
            max_age_secs,
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Challenge {
    scheme: String,
    // Names in lower case, values unquoted.
    params: Vec<(String, String)>,
}

// RFC 9110 section 11.6.1: `#challenge`, each `auth-scheme [ 1*SP ( token68 / #auth-param ) ]`. A comma separates both
// challenges and the parameters of one, so an element of the list is a new challenge when it starts with a token that
// no `=` follows.
fn challenges(field: &str) -> Option<Vec<Challenge>> {
    let mut found: Vec<Challenge> = Vec::new();
    for element in elements(field)? {
        let element = element.trim_matches(is_ows);
        if element.is_empty() {
            continue;
        }
        let (first, rest) = split_token(element);
        if first.is_empty() {
            return None;
        }
        match rest.trim_start_matches(is_ows) {
            after if after.starts_with('=') => {
                let value = value(&after[1..])?;
                found.last_mut()?.params.push((first.to_ascii_lowercase(), value));
            }
            "" => found.push(Challenge {
                scheme: first.to_owned(),
                params: Vec::new(),
            }),
            after if after.len() < rest.len() => {
                let mut challenge = Challenge {
                    scheme: first.to_owned(),
                    params: Vec::new(),
                };
                if !is_token68(after) {
                    let (name, value_part) = split_token(after);
                    let value_part = value_part.trim_start_matches(is_ows);
                    if name.is_empty() || !value_part.starts_with('=') {
                        return None;
                    }
                    challenge
                        .params
                        .push((name.to_ascii_lowercase(), value(&value_part[1..])?));
                }
                found.push(challenge);
            }
            _ => return None,
        }
    }
    Some(found)
}

// The list's elements, split at commas outside a quoted-string.
fn elements(field: &str) -> Option<Vec<&str>> {
    let mut found = Vec::new();
    let (mut start, mut quoted, mut escaped) = (0, false, false);
    for (at, byte) in field.bytes().enumerate() {
        match (quoted, escaped, byte) {
            (true, true, _) => escaped = false,
            (true, false, b'\\') => escaped = true,
            (_, _, b'"') => quoted = !quoted,
            (false, _, b',') => {
                found.push(&field[start..at]);
                start = at + 1;
            }
            _ => {}
        }
    }
    if quoted {
        return None;
    }
    found.push(&field[start..]);
    Some(found)
}

// A token, or a quoted-string with its escapes undone, then nothing but whitespace.
fn value(text: &str) -> Option<String> {
    let text = text.trim_start_matches(is_ows);
    let (value, rest) = match text.strip_prefix('"') {
        Some(quoted) => {
            let mut value = String::new();
            let mut characters = quoted.char_indices();
            let end = loop {
                match characters.next()? {
                    (_, '\\') => value.push(characters.next()?.1),
                    (at, '"') => break at + 1,
                    (_, character) => value.push(character),
                }
            };
            (value, &quoted[end..])
        }
        None => {
            let (token, rest) = split_token(text);
            if token.is_empty() {
                return None;
            }
            (token.to_owned(), rest)
        }
    };
    rest.trim_matches(is_ows).is_empty().then_some(value)
}

fn split_token(text: &str) -> (&str, &str) {
    let end = text.find(|character: char| !is_tchar(character)).unwrap_or(text.len());
    text.split_at(end)
}

fn is_tchar(character: char) -> bool {
    character.is_ascii_alphanumeric() || "!#$%&'*+-.^_`|~".contains(character)
}

fn is_token68(text: &str) -> bool {
    let body = text.trim_end_matches('=');
    !body.is_empty()
        && body
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-._~+/".contains(character))
}

fn is_ows(character: char) -> bool {
    character == ' ' || character == '\t'
}

#[cfg(test)]
mod tests {
    use reqwest::header::HeaderValue;

    use super::*;

    fn read(fields: &[&str]) -> Option<StepUpChallenge> {
        let mut headers = HeaderMap::new();
        for field in fields {
            headers.append(WWW_AUTHENTICATE, HeaderValue::from_str(field).expect("a header value"));
        }
        StepUpChallenge::from_headers(&headers)
    }

    fn challenge(acr_values: &[&str], max_age_secs: Option<u64>) -> Option<StepUpChallenge> {
        Some(StepUpChallenge {
            acr_values: acr_values.iter().map(|value| (*value).to_owned()).collect(),
            max_age_secs,
        })
    }

    #[test]
    fn the_server_s_challenge_names_its_methods_in_order_and_the_age() {
        let field = r#"Bearer error="insufficient_user_authentication", error_description="A fresh step-up is required", acr_values="urn:tablepro:acr:passkey urn:tablepro:acr:email-code", max_age=300"#;

        assert_eq!(
            read(&[field]),
            challenge(&["urn:tablepro:acr:passkey", "urn:tablepro:acr:email-code"], Some(300))
        );
    }

    // RFC 9470 section 3's examples: one with acr_values alone, one with max_age alone.
    #[test]
    fn either_parameter_may_come_alone() {
        assert_eq!(
            read(&[
                r#"Bearer error="insufficient_user_authentication", error_description="A different authentication level is required", acr_values="myACR""#
            ]),
            challenge(&["myACR"], None)
        );
        assert_eq!(
            read(&[
                r#"Bearer error="insufficient_user_authentication", error_description="More recent authentication is required", max_age="5""#
            ]),
            challenge(&[], Some(5))
        );
    }

    #[test]
    fn the_challenge_is_found_beside_others_in_one_field_or_in_another() {
        let one_field = r#"DPoP algs="EdDSA", error="use_dpop_nonce", Bearer realm="api", error="insufficient_user_authentication", acr_values="urn:tablepro:acr:passkey", max_age=300"#;
        let token68 =
            r#"Negotiate a87421000492aa874209af8bc028==, Bearer error="insufficient_user_authentication", max_age=60"#;

        assert_eq!(read(&[one_field]), challenge(&["urn:tablepro:acr:passkey"], Some(300)));
        assert_eq!(read(&[token68]), challenge(&[], Some(60)));
        assert_eq!(
            read(&[
                r#"Basic realm="admin""#,
                r#"bearer ERROR="insufficient_user_authentication" , Max_Age = 10"#
            ]),
            challenge(&[], Some(10))
        );
    }

    #[test]
    fn a_quoted_value_keeps_its_commas_and_loses_its_escapes() {
        let field = r#"Bearer error_description="old, \"weak\" sign-in", error="insufficient_user_authentication", acr_values="a\,b  c""#;

        assert_eq!(read(&[field]), challenge(&["a,b", "c"], None));
    }

    #[test]
    fn another_error_or_scheme_asks_for_no_step_up() {
        assert_eq!(
            read(&[r#"Bearer error="invalid_token", error_description="expired""#]),
            None
        );
        assert_eq!(read(&[r#"Bearer realm="api""#]), None);
        assert_eq!(
            read(&[r#"Basic error="insufficient_user_authentication", max_age=5"#]),
            None
        );
        assert_eq!(read(&[]), None);
    }

    #[test]
    fn a_field_that_does_not_parse_or_a_bad_parameter_asks_for_nothing() {
        let unquoted_end = r#"Bearer error="insufficient_user_authentication, max_age=5"#;
        let twice = r#"Bearer error="insufficient_user_authentication", max_age=5, max_age=6"#;
        let negative = r#"Bearer error="insufficient_user_authentication", max_age=-1"#;
        let fraction = r#"Bearer error="insufficient_user_authentication", max_age="1.5""#;
        let past_u64 = r#"Bearer error="insufficient_user_authentication", max_age=18446744073709551616"#;
        let param_first = r#"error="insufficient_user_authentication", Bearer max_age=5"#;
        let stray = r#"Bearer error="insufficient_user_authentication" max_age=5"#;

        for field in [unquoted_end, twice, negative, fraction, past_u64, param_first, stray] {
            assert_eq!(read(&[field]), None, "{field}");
        }
    }

    #[test]
    fn a_bad_field_does_not_hide_a_good_one() {
        assert_eq!(
            read(&[
                r#"Bearer error="unterminated"#,
                r#"Bearer error="insufficient_user_authentication", acr_values="urn:tablepro:acr:passkey""#
            ]),
            challenge(&["urn:tablepro:acr:passkey"], None)
        );
    }
}
