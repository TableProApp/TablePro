#[cfg(target_os = "windows")]
mod windows;

#[cfg(not(target_os = "windows"))]
mod nix;

use hickory_proto::rr::RData;

use crate::{
    bson::Bson,
    client::{
        auth::{
            sasl::{SaslContinue, SaslResponse, SaslStart},
            Credential,
            GSSAPI_STR,
        },
        options::ServerApi,
    },
    cmap::Connection,
    error::{Error, Redact, Result},
    options::ResolverConfig,
};

const SERVICE_NAME: &str = "SERVICE_NAME";
const CANONICALIZE_HOST_NAME: &str = "CANONICALIZE_HOST_NAME";
const SERVICE_REALM: &str = "SERVICE_REALM";
const SERVICE_HOST: &str = "SERVICE_HOST";

#[derive(Debug, Clone)]
struct GssapiProperties {
    pub service_name: String,
    pub canonicalize_host_name: CanonicalizeHostName,
    pub service_realm: Option<String>,
    pub service_host: Option<String>,
}

#[derive(Debug, Default, Clone, PartialEq)]
enum CanonicalizeHostName {
    #[default]
    None,
    Forward,
    ForwardAndReverse,
}

pub(crate) async fn authenticate_stream(
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
    resolver_config: Option<&ResolverConfig>,
) -> Result<()> {
    let properties = GssapiProperties::from_credential(credential)?;

    let conn_host = conn.address.host().to_string();
    let hostname = properties.service_host.as_ref().unwrap_or(&conn_host);
    let hostname = canonicalize_hostname(
        hostname,
        &properties.canonicalize_host_name,
        resolver_config,
    )
    .await
    .unwrap_or_else(|_| hostname.clone());

    let user_principal = credential.username.clone();
    let service_principal = properties.service_principal_name(&hostname, user_principal.as_ref());
    let source = credential.source.as_deref().unwrap_or("$external");

    #[cfg(target_os = "windows")]
    let (mut authenticator, initial_token) = windows::SspiAuthenticator::init(
        user_principal,
        credential.password.clone(),
        service_principal,
    )?;

    #[cfg(not(target_os = "windows"))]
    let (mut authenticator, initial_token) =
        nix::GssapiAuthenticator::init(user_principal, service_principal)?;

    let command = SaslStart::new(
        source.to_string(),
        crate::client::auth::AuthMechanism::Gssapi,
        initial_token,
        server_api.cloned(),
    )
    .into_command()?;

    let response_doc = conn.send_message(command).await?;
    let sasl_response =
        SaslResponse::parse(GSSAPI_STR, response_doc.auth_response_body(GSSAPI_STR)?)?;

    let mut conversation_id = Some(sasl_response.conversation_id);
    let mut payload = sasl_response.payload;

    // Limit number of auth challenge steps (typically, only one step is needed, however
    // different configurations may require more).
    for _ in 0..10 {
        let challenge = payload.as_slice();
        let output_token = authenticator.step(challenge)?;

        // The step may return None, which is a valid final step. We still need to
        // send a saslContinue command, so we send an empty payload if there is no
        // token.
        let token = output_token.unwrap_or(vec![]);
        let command = SaslContinue::new(
            source.to_string(),
            conversation_id.clone().unwrap(),
            token,
            server_api.cloned(),
        )
        .into_command();

        let response_doc = conn.send_message(command).await?;
        let sasl_response =
            SaslResponse::parse(GSSAPI_STR, response_doc.auth_response_body(GSSAPI_STR)?)?;

        conversation_id = Some(sasl_response.conversation_id);
        payload = sasl_response.payload;

        // Although unlikely, there are cases where authentication can be done
        // at this point.
        if sasl_response.done {
            return Ok(());
        }

        // The authenticator is considered "complete" when the Kerberos auth
        // process is done. However, this is not the end of the full auth flow.
        // We no longer need to issue challenges to the authenticator, so we
        // break the loop and continue with the rest of the flow.
        if authenticator.is_complete() {
            break;
        }
    }

    let output_token = authenticator.do_unwrap_wrap(payload.as_slice())?;
    let command = SaslContinue::new(
        source.to_string(),
        conversation_id.unwrap(),
        output_token,
        server_api.cloned(),
    )
    .into_command();

    let response_doc = conn.send_message(command).await?;
    let sasl_response =
        SaslResponse::parse(GSSAPI_STR, response_doc.auth_response_body(GSSAPI_STR)?)?;

    if sasl_response.done {
        Ok(())
    } else {
        Err(Error::authentication_error(
            GSSAPI_STR,
            "GSSAPI authentication failed after 10 attempts",
        ))
    }
}

impl GssapiProperties {
    pub fn from_credential(credential: &Credential) -> Result<Self> {
        let mut properties = GssapiProperties {
            service_name: "mongodb".to_string(),
            canonicalize_host_name: CanonicalizeHostName::None,
            service_realm: None,
            service_host: None,
        };

        if let Some(mechanism_properties) = &credential.mechanism_properties {
            if let Some(Bson::String(name)) = mechanism_properties.get(SERVICE_NAME) {
                properties.service_name = name.clone();
            }

            if let Some(canonicalize) = mechanism_properties.get(CANONICALIZE_HOST_NAME) {
                properties.canonicalize_host_name = match canonicalize {
                    Bson::String(s) => match s.as_str() {
                        "none" => CanonicalizeHostName::None,
                        "forward" => CanonicalizeHostName::Forward,
                        "forwardAndReverse" => CanonicalizeHostName::ForwardAndReverse,
                        _ => {
                            return Err(Error::authentication_error(
                                GSSAPI_STR,
                                format!(
                                    "Invalid CANONICALIZE_HOST_NAME value: {s}. Valid values are \
                                     'none', 'forward', 'forwardAndReverse'",
                                )
                                .as_str(),
                            ))
                        }
                    },
                    Bson::Boolean(true) => CanonicalizeHostName::ForwardAndReverse,
                    Bson::Boolean(false) => CanonicalizeHostName::None,
                    _ => {
                        return Err(Error::authentication_error(
                            GSSAPI_STR,
                            "CANONICALIZE_HOST_NAME must be a string or boolean",
                        ))
                    }
                };
            }

            if let Some(Bson::String(realm)) = mechanism_properties.get(SERVICE_REALM) {
                properties.service_realm = Some(realm.clone());
            }

            if let Some(Bson::String(host)) = mechanism_properties.get(SERVICE_HOST) {
                properties.service_host = Some(host.clone());
            }
        }

        Ok(properties)
    }

    fn service_principal_name(self, hostname: &String, user_principal: Option<&String>) -> String {
        // Set the service principal name in addition to the user provided properties
        let service_name: &str = self.service_name.as_ref();
        let mut service_principal = format!("{service_name}/{hostname}");
        if let Some(service_realm) = self.service_realm.as_ref() {
            service_principal = format!("{service_principal}@{service_realm}");
        } else if let Some(user_principal) = user_principal {
            if let Some(idx) = user_principal.find('@') {
                // If no SERVICE_REALM was specified, use realm specified in the
                // username. Note that `realm` starts with '@'.
                let (_, realm) = user_principal.split_at(idx);
                service_principal = format!("{service_principal}{realm}");
            }
        }

        service_principal
    }
}

async fn canonicalize_hostname(
    hostname: &str,
    mode: &CanonicalizeHostName,
    resolver_config: Option<&ResolverConfig>,
) -> Result<String> {
    if mode == &CanonicalizeHostName::None {
        return Ok(hostname.to_string());
    }

    let resolver =
        crate::runtime::AsyncResolver::new(resolver_config.map(|c| c.inner.clone())).await?;

    let hostname = match mode {
        CanonicalizeHostName::Forward => {
            let lookup_records = resolver.cname_lookup(hostname).await?;

            if !lookup_records.answers().is_empty() {
                // As long as there is a record, we can return the original hostname.
                // Although the spec says to return the canonical name, this is not
                // done by any drivers in practice since the majority of them use
                // libraries that do not follow CNAME chains. Also, we do not want to
                // use the canonical name since it will likely differ from the input
                // name, and the use of the input name is required for the service
                // principal to be accepted by the GSSAPI auth flow.
                hostname.to_lowercase().to_string()
            } else {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("No addresses found for hostname: {}", Redact(hostname)),
                ));
            }
        }
        CanonicalizeHostName::ForwardAndReverse => {
            // forward lookup
            let ips = resolver.ip_lookup(hostname).await?;

            if let Some(first_address) = ips.iter().next() {
                // reverse lookup
                match resolver.reverse_lookup(first_address).await {
                    Ok(reverse_lookup) => {
                        if let Some(name) =
                            reverse_lookup.answers().iter().find_map(|r| match &r.data {
                                RData::PTR(ptr) => Some(ptr),
                                _ => None,
                            })
                        {
                            name.to_lowercase().to_string()
                        } else {
                            hostname.to_lowercase()
                        }
                    }
                    Err(_) => hostname.to_lowercase(),
                }
            } else {
                return Err(Error::authentication_error(
                    GSSAPI_STR,
                    &format!("No addresses found for hostname: {}", Redact(hostname)),
                ));
            }
        }
        CanonicalizeHostName::None => unreachable!(),
    };

    // Sometimes reverse lookup results in a trailing "." since that is the correct
    // way to present a FQDN. However, GSSAPI rejects the trailing "." so we remove
    // it here manually.
    let hostname = hostname.trim_end_matches(".");

    Ok(hostname.to_string())
}
