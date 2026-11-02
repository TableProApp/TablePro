use secrecy::{ExposeSecret, SecretString};
use subtle::ConstantTimeEq;

/// Random bytes in a token: as many as a 256-bit key has.
const TOKEN_BYTES: usize = 32;

/// Marks the text as a TablePro token, so a secret scanner or a person
/// reading a client's config can tell what it is.
const PREFIX: &str = "tp_";

/// The bearer token every request carries. Any program of any user on
/// the machine can reach 127.0.0.1, so the token is what tells the
/// user's own client apart from them.
#[derive(Clone)]
pub struct AccessToken(SecretString);

#[derive(Debug, thiserror::Error)]
#[error("the system's random source failed: {0}")]
pub struct TokenError(getrandom::Error);

impl AccessToken {
    pub fn generate() -> Result<Self, TokenError> {
        let mut bytes = [0u8; TOKEN_BYTES];
        getrandom::fill(&mut bytes).map_err(TokenError)?;
        let mut text = String::with_capacity(PREFIX.len() + TOKEN_BYTES * 2);
        text.push_str(PREFIX);
        for byte in bytes {
            text.push(hex_digit(byte >> 4));
            text.push(hex_digit(byte & 0x0f));
        }
        Ok(Self(SecretString::from(text)))
    }

    /// A token read back from the keyring. An empty one would let any
    /// `Bearer ` header in, so it is refused.
    pub fn from_secret(secret: SecretString) -> Option<Self> {
        (!secret.expose_secret().trim().is_empty()).then_some(Self(secret))
    }

    pub fn secret(&self) -> &SecretString {
        &self.0
    }

    /// Whether an `Authorization` header value presents this token. The
    /// comparison takes as long whatever the header holds, so timing a
    /// guess tells nothing about how much of it was right.
    pub fn authorizes(&self, header: &[u8]) -> bool {
        let Some(presented) = bearer(header) else {
            return false;
        };
        bool::from(presented.ct_eq(self.0.expose_secret().as_bytes()))
    }
}

impl std::fmt::Debug for AccessToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AccessToken(..)")
    }
}

/// The credentials of a `Bearer` header. The scheme is case-insensitive
/// (RFC 9110, 11.1); the token is not.
fn bearer(header: &[u8]) -> Option<&[u8]> {
    let (scheme, rest) = header.split_at_checked(6)?;
    if !scheme.eq_ignore_ascii_case(b"bearer") {
        return None;
    }
    let token = rest.strip_prefix(b" ")?.trim_ascii();
    (!token.is_empty()).then_some(token)
}

fn hex_digit(nibble: u8) -> char {
    char::from(b"0123456789abcdef"[usize::from(nibble & 0x0f)])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(text: &str) -> AccessToken {
        AccessToken::from_secret(SecretString::from(text.to_owned())).expect("a token")
    }

    #[test]
    fn a_generated_token_is_prefixed_hex_and_new_each_time() {
        let first = AccessToken::generate().expect("a token");
        let second = AccessToken::generate().expect("a token");
        let text = first.secret().expose_secret();

        assert_eq!(text.len(), PREFIX.len() + TOKEN_BYTES * 2);
        assert!(text.starts_with(PREFIX));
        assert!(text[PREFIX.len()..].bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(text, second.secret().expose_secret());
    }

    #[test]
    fn only_the_same_token_under_the_bearer_scheme_authorizes() {
        let token = token("tp_abc123");

        assert!(token.authorizes(b"Bearer tp_abc123"));
        assert!(token.authorizes(b"bearer tp_abc123"));
        assert!(token.authorizes(b"Bearer tp_abc123 "));
        assert!(!token.authorizes(b"Bearer tp_abc12"));
        assert!(!token.authorizes(b"Bearer tp_abc1234"));
        assert!(!token.authorizes(b"Bearer TP_ABC123"));
        assert!(!token.authorizes(b"Basic tp_abc123"));
        assert!(!token.authorizes(b"Bearertp_abc123"));
        assert!(!token.authorizes(b"tp_abc123"));
        assert!(!token.authorizes(b"Bearer "));
        assert!(!token.authorizes(b""));
    }

    #[test]
    fn an_empty_stored_token_is_no_token() {
        assert!(AccessToken::from_secret(SecretString::from("  ".to_owned())).is_none());
    }
}
