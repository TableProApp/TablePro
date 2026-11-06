use std::sync::Mutex;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_account::{BrowserLauncher, RefreshTokenVault, Url};
use tablepro_core::credentials::SecretError;

#[derive(Default)]
pub(crate) struct MemoryKeyring(Mutex<Option<SecretString>>);

#[async_trait]
impl RefreshTokenVault for MemoryKeyring {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        Ok(self.0.lock().expect("the keyring").clone())
    }

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
        *self.0.lock().expect("the keyring") = Some(token.clone());
        Ok(())
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        *self.0.lock().expect("the keyring") = None;
        Ok(())
    }
}

// Approves at once, as the account service's consent screen would.
pub(crate) struct Approving;

#[async_trait]
impl BrowserLauncher for Approving {
    async fn open(&self, url: &Url) -> Result<(), String> {
        let asked = |name: &str| {
            url.query_pairs()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.into_owned())
                .ok_or(format!("no {name}"))
        };
        let mut redirect = Url::parse(&asked("redirect_uri")?).map_err(|error| error.to_string())?;
        redirect
            .query_pairs_mut()
            .append_pair("code", "stub-code")
            .append_pair("state", &asked("state")?);
        std::thread::spawn(move || deliver(&redirect));
        Ok(())
    }
}

// Hands the loopback listener the redirect the browser would follow.
pub(crate) fn deliver(redirect: &Url) {
    let target = format!(
        "{}:{}",
        redirect.host_str().expect("a host"),
        redirect.port().expect("a port")
    );
    let mut stream = std::net::TcpStream::connect(target).expect("the loopback listener");
    let path = format!("{}?{}", redirect.path(), redirect.query().unwrap_or_default());
    std::io::Write::write_all(
        &mut stream,
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").as_bytes(),
    )
    .expect("the redirect sent");
    let mut reply = String::new();
    std::io::Read::read_to_string(&mut stream, &mut reply).expect("the listener's answer");
}
