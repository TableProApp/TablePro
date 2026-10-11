use crate::{
    client::{
        auth::{
            sasl::{SaslResponse, SaslStart},
            AuthMechanism,
            Credential,
        },
        options::ServerApi,
    },
    cmap::Connection,
    error::{Error, Result},
};

pub(crate) async fn authenticate_stream(
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
) -> Result<()> {
    let source = credential.source.as_deref().unwrap_or("$external");
    let username = credential
        .username
        .as_ref()
        .ok_or_else(|| Error::authentication_error("PLAIN", "no username supplied"))?;

    let password = credential
        .password
        .as_ref()
        .ok_or_else(|| Error::authentication_error("PLAIN", "no password supplied"))?;

    let sasl_start = SaslStart::new(
        source.into(),
        AuthMechanism::Plain,
        payload_bytes(username, password),
        server_api.cloned(),
    )
    .into_command()?;

    let response = conn.send_message(sasl_start).await?;
    let sasl_response = SaslResponse::parse("PLAIN", response.auth_response_body("PLAIN")?)?;

    if !sasl_response.done {
        return Err(Error::invalid_authentication_response("PLAIN"));
    }

    Ok(())
}

fn payload_bytes(username: &str, password: &str) -> Vec<u8> {
    let mut bytes = vec![0];
    bytes.extend(username.as_bytes());

    bytes.push(0);
    bytes.extend(password.as_bytes());

    bytes
}
