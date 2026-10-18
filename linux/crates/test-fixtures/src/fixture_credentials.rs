use std::fmt;

use uuid::Uuid;

#[derive(Clone, PartialEq, Eq)]
pub struct FixtureCredentials {
    pub username: String,
    pub password: String,
}

impl FixtureCredentials {
    pub(crate) fn new(username: &str, password: &str) -> Self {
        Self {
            username: username.to_owned(),
            password: password.to_owned(),
        }
    }

    pub(crate) fn generate_password() -> String {
        Uuid::new_v4().simple().to_string()
    }
}

impl fmt::Debug for FixtureCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FixtureCredentials")
            .field("username", &self.username)
            .field("password", &"<redacted>")
            .finish()
    }
}
