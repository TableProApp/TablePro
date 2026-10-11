use crate::bson::{rawdoc, RawBson};

use crate::{
    bson::{spec::BinarySubtype, Binary, Bson, Document},
    bson_compat::cstr,
    bson_util,
    client::{auth::AuthMechanism, options::ServerApi},
    cmap::Command,
    error::{Error, Result},
    operation::{CommandErrorBody, CommandResponse},
};

/// Encapsulates the command building of a `saslStart` command.
pub(super) struct SaslStart {
    source: String,
    mechanism: AuthMechanism,
    payload: Vec<u8>,
    server_api: Option<ServerApi>,
}

impl SaslStart {
    pub(super) fn new(
        source: String,
        mechanism: AuthMechanism,
        payload: Vec<u8>,
        server_api: Option<ServerApi>,
    ) -> Self {
        Self {
            source,
            mechanism,
            payload,
            server_api,
        }
    }

    pub(super) fn into_command(self) -> Result<Command> {
        let mut body = rawdoc! {
            "saslStart": 1,
            "mechanism": self.mechanism.as_str(),
            "payload": Binary { subtype: BinarySubtype::Generic, bytes: self.payload },
        };
        if self.mechanism == AuthMechanism::ScramSha1
            || self.mechanism == AuthMechanism::ScramSha256
        {
            body.append(cstr!("options"), rawdoc! { "skipEmptyExchange": true });
        }

        let mut command = Command::new_raw("saslStart", self.source, body);
        if let Some(server_api) = self.server_api {
            command.set_server_api(&server_api);
        }

        Ok(command)
    }
}

/// Encapsulates the command building of a `saslContinue` command.
pub(super) struct SaslContinue {
    source: String,
    conversation_id: Bson,
    payload: Vec<u8>,
    server_api: Option<ServerApi>,
}

impl SaslContinue {
    pub(super) fn new(
        source: String,
        conversation_id: Bson,
        payload: Vec<u8>,
        server_api: Option<ServerApi>,
    ) -> Self {
        Self {
            source,
            conversation_id,
            payload,
            server_api,
        }
    }

    pub(super) fn into_command(self) -> Command {
        // Unwrap safety: the Bson -> RawBson conversion is actually infallible
        let raw_id: RawBson = self.conversation_id.try_into().unwrap();
        let body = rawdoc! {
            "saslContinue": 1,
            "conversationId": raw_id,
            "payload": Binary { subtype: BinarySubtype::Generic, bytes: self.payload },
        };

        let mut command = Command::new_raw("saslContinue", self.source, body);
        if let Some(server_api) = self.server_api {
            command.set_server_api(&server_api);
        }

        command
    }
}

/// Validates that a `saslStart` or `saslContinue` command response is successful.
fn validate_command_success(auth_mechanism: &str, response: &Document) -> Result<()> {
    let ok = match response.get("ok") {
        Some(ok) => ok,
        None => return Ok(()),
    };

    match bson_util::get_int(ok) {
        Some(1) => Ok(()),
        Some(_) => {
            let source = crate::bson_compat::deserialize_from_bson::<
                CommandResponse<CommandErrorBody>,
            >(Bson::Document(response.clone()))
            .map(|cmd_resp| cmd_resp.body.into())
            .ok();
            Err(Error::authentication_error(
                auth_mechanism,
                response
                    .get_str("errmsg")
                    .unwrap_or("Authentication failure"),
            )
            .with_source(source))
        }
        _ => Err(Error::invalid_authentication_response(auth_mechanism)),
    }
}

/// Encapsulates the parsing of the response to a `saslStart` or `saslContinue` command.
#[derive(Debug)]
pub(super) struct SaslResponse {
    pub(super) conversation_id: Bson,
    pub(super) done: bool,
    pub(super) payload: Vec<u8>,
}

impl SaslResponse {
    pub(super) fn parse(auth_mechanism: &str, mut response: Document) -> Result<Self> {
        validate_command_success(auth_mechanism, &response)?;

        let conversation_id = response
            .remove("conversationId")
            .ok_or_else(|| Error::invalid_authentication_response(auth_mechanism))?;
        let done = response
            .remove("done")
            .and_then(|b| b.as_bool())
            .ok_or_else(|| Error::invalid_authentication_response(auth_mechanism))?;
        let payload = response
            .get_binary_generic_mut("payload")
            .map_err(|_| Error::invalid_authentication_response(auth_mechanism))?
            .drain(..)
            .collect();

        Ok(SaslResponse {
            conversation_id,
            done,
            payload,
        })
    }
}
