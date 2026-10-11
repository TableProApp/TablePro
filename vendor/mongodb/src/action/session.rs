use crate::{
    bson::Timestamp,
    client::options::{SessionOptions, TransactionOptions},
    error::Result,
    Client,
    ClientSession,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc};

impl Client {
    /// Starts a new [`ClientSession`].
    ///
    /// `await` will return d[`Result<ClientSession>`].
    #[deeplink]
    #[options_doc(start_session)]
    pub fn start_session(&self) -> StartSession<'_> {
        StartSession {
            client: self,
            options: None,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Client {
    /// Starts a new [`ClientSession`].
    ///
    /// [run](StartSession::run) will return d[`Result<crate::sync::ClientSession>`].
    #[deeplink]
    #[options_doc(start_session, "run")]
    pub fn start_session(&self) -> StartSession<'_> {
        self.async_client.start_session()
    }
}

/// Starts a new [`ClientSession`].  Construct with [`Client::start_session`].
#[must_use]
pub struct StartSession<'a> {
    client: &'a Client,
    options: Option<SessionOptions>,
}

#[option_setters(crate::client::options::SessionOptions)]
#[export_doc(start_session)]
impl StartSession<'_> {}

#[action_impl(sync = crate::sync::ClientSession)]
impl<'a> Action for StartSession<'a> {
    type Future = StartSessionFuture;

    async fn execute(self) -> Result<ClientSession> {
        if let Some(options) = &self.options {
            options.validate()?;
        }
        Ok(ClientSession::new(self.client.clone(), self.options, false).await)
    }
}
