use std::{collections::HashMap, time::Duration};

use crate::bson::Array;
use mongocrypt::ctx::KmsProvider;
use serde::Deserialize;
use typed_builder::TypedBuilder;

use crate::{
    bson::{Bson, Document},
    client::options::TlsOptions,
    error::{Error, Result},
    serde_util,
    Namespace,
};

use super::client_encryption::KmsConnectCallback;

/// Options related to automatic encryption.
///
/// Automatic encryption is an enterprise only feature that only applies to operations on a
/// collection. Automatic encryption is not supported for operations on a database or view, and
/// operations that are not bypassed will result in error (see [libmongocrypt: Auto Encryption
/// Allow-List](
/// https://specifications.readthedocs.io/en/latest/client-side-encryption/client-side-encryption/#libmongocrypt-auto-encryption-allow-list
/// )). To bypass automatic encryption for all operations, set bypassAutoEncryption=true in
/// AutoEncryptionOpts.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AutoEncryptionOptions {
    /// Used for data key queries.  Will default to an internal client if not set.
    #[serde(skip)]
    pub(crate) key_vault_client: Option<crate::Client>,
    /// A collection that contains all data keys used for encryption and decryption (aka the key
    /// vault collection).
    #[serde(default = "default_key_vault_namespace")]
    pub(crate) key_vault_namespace: Namespace,
    /// Options individual to each KMS provider.
    pub(crate) kms_providers: KmsProviders,
    /// Specify a JSONSchema locally.
    ///
    /// Supplying a `schema_map` provides more security than relying on JSON Schemas obtained from
    /// the server. It protects against a malicious server advertising a false JSON Schema, which
    /// could trick the client into sending unencrypted data that should be encrypted.
    ///
    /// Schemas supplied in the `schema_map` only apply to configuring automatic encryption for
    /// client side encryption. Other validation rules in the JSON schema will not be enforced by
    /// the driver and will result in an error.
    pub(crate) schema_map: Option<HashMap<String, Document>>,
    /// Disable automatic encryption and do not spawn mongocryptd.  Defaults to false.
    pub(crate) bypass_auto_encryption: Option<bool>,
    /// Options related to mongocryptd.
    pub(crate) extra_options: Option<Document>,
    /// Maps namespace to encrypted fields.
    ///
    /// Supplying an `encrypted_fields_map` provides more security than relying on an
    /// encryptedFields obtained from the server. It protects against a malicious server
    /// advertising a false encryptedFields.
    pub(crate) encrypted_fields_map: Option<HashMap<String, Document>>,
    /// Disable serverside processing of encrypted indexed fields, allowing use of explicit
    /// encryption with queryable encryption.
    pub(crate) bypass_query_analysis: Option<bool>,
    /// Disable loading crypt_shared.
    #[cfg(test)]
    #[serde(skip)]
    pub(crate) disable_crypt_shared: Option<bool>,
    /// The duration after which the data encryption key cache expires. Defaults to 60 seconds if
    /// unset.
    #[serde(
        default,
        rename = "keyExpirationMS",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub(crate) key_cache_expiration: Option<Duration>,
    #[serde(skip)]
    pub(crate) kms_connect_callback: Option<KmsConnectCallback>,
    #[serde(skip)]
    pub(crate) credential_providers: Option<CredentialProviders>,
}

fn default_key_vault_namespace() -> Namespace {
    Namespace {
        db: "keyvault".to_string(),
        coll: "datakeys".to_string(),
    }
}

impl AutoEncryptionOptions {
    pub(crate) fn new(key_vault_namespace: Namespace, kms_providers: KmsProviders) -> Self {
        Self {
            key_vault_namespace,
            kms_providers,
            key_vault_client: None,
            schema_map: None,
            bypass_auto_encryption: None,
            extra_options: None,
            encrypted_fields_map: None,
            bypass_query_analysis: None,
            #[cfg(test)]
            disable_crypt_shared: None,
            key_cache_expiration: None,
            kms_connect_callback: None,
            credential_providers: None,
        }
    }
}

#[derive(Deserialize, Debug, Clone)]
pub(crate) struct KmsProviders {
    #[serde(flatten)]
    credentials: HashMap<KmsProvider, Document>,
    #[serde(skip)]
    tls_options: Option<KmsProvidersTlsOptions>,
}

pub(crate) type KmsProvidersTlsOptions = HashMap<KmsProvider, TlsOptions>;

impl KmsProviders {
    pub(crate) fn new(
        providers: impl IntoIterator<Item = (KmsProvider, crate::bson::Document, Option<TlsOptions>)>,
    ) -> Result<Self> {
        let mut credentials = HashMap::new();
        let mut tls_options = None;
        for (provider, conf, tls) in providers.into_iter() {
            credentials.insert(provider.clone(), conf);
            if let Some(tls) = tls {
                tls_options
                    .get_or_insert_with(KmsProvidersTlsOptions::new)
                    .insert(provider, tls);
            }
        }
        if credentials.is_empty() {
            return Err(crate::error::Error::invalid_argument("empty kms_providers"));
        }
        Ok(Self {
            credentials,
            tls_options,
        })
    }

    pub(crate) fn credentials_doc(&self) -> Result<Document> {
        Ok(crate::bson_compat::serialize_to_document(
            &self.credentials,
        )?)
    }

    pub(crate) fn tls_options(&self) -> Option<&KmsProvidersTlsOptions> {
        self.tls_options.as_ref()
    }

    pub(crate) fn credentials(&self) -> &HashMap<KmsProvider, Document> {
        &self.credentials
    }

    pub(crate) fn validate_credential_providers(
        &self,
        credential_providers: &Option<CredentialProviders>,
    ) -> Result<()> {
        let Some(credential_providers) = credential_providers else {
            return Ok(());
        };
        #[cfg(feature = "aws-auth")]
        if credential_providers.aws.is_some() {
            self.validate_on_demand(&KmsProvider::aws())?;
        }
        Ok(())
    }

    #[cfg(feature = "aws-auth")]
    fn validate_on_demand(&self, provider: &KmsProvider) -> Result<()> {
        if self.credentials.get(provider).is_none_or(|c| !c.is_empty()) {
            return Err(Error::invalid_argument(format!(
                "a custom {} credential provider requires the corresponding KMS provider to be \
                 configured with an empty credentials document",
                provider.as_string(),
            )));
        }
        Ok(())
    }
}

impl AutoEncryptionOptions {
    pub(crate) fn extra_option<'a, Opt: ExtraOption<'a>>(
        &'a self,
        opt: &Opt,
    ) -> Result<Option<Opt::Output>> {
        let key = opt.key();
        match self.extra_options.as_ref().and_then(|o| o.get(key)) {
            None => Ok(None),
            Some(b) => match Opt::as_type(b) {
                Some(v) => Ok(Some(v)),
                None => Err(Error::invalid_argument(format!(
                    "unexpected type for extra option {key:?}: {b:?}"
                ))),
            },
        }
    }
}

pub(crate) trait ExtraOption<'a> {
    type Output;
    fn key(&self) -> &'static str;
    fn as_type(input: &'a Bson) -> Option<Self::Output>;
}

pub(crate) struct ExtraOptionStr(&'static str);

impl<'a> ExtraOption<'a> for ExtraOptionStr {
    type Output = &'a str;
    fn key(&self) -> &'static str {
        self.0
    }
    fn as_type(input: &'a Bson) -> Option<&'a str> {
        input.as_str()
    }
}

pub(crate) struct ExtraOptionBool(&'static str);

impl<'a> ExtraOption<'a> for ExtraOptionBool {
    type Output = bool;
    fn key(&self) -> &'static str {
        self.0
    }
    fn as_type(input: &'a Bson) -> Option<bool> {
        input.as_bool()
    }
}

pub(crate) struct ExtraOptionArray(&'static str);

impl<'a> ExtraOption<'a> for ExtraOptionArray {
    type Output = &'a Array;
    fn key(&self) -> &'static str {
        self.0
    }
    fn as_type(input: &'a Bson) -> Option<&'a Array> {
        input.as_array()
    }
}

pub(crate) const EO_MONGOCRYPTD_URI: ExtraOptionStr = ExtraOptionStr("mongocryptdURI");
pub(crate) const EO_MONGOCRYPTD_BYPASS_SPAWN: ExtraOptionBool =
    ExtraOptionBool("mongocryptdBypassSpawn");
pub(crate) const EO_MONGOCRYPTD_SPAWN_PATH: ExtraOptionStr = ExtraOptionStr("mongocryptdSpawnPath");
pub(crate) const EO_MONGOCRYPTD_SPAWN_ARGS: ExtraOptionArray =
    ExtraOptionArray("mongocryptdSpawnArgs");
pub(crate) const EO_CRYPT_SHARED_LIB_PATH: ExtraOptionStr = ExtraOptionStr("cryptSharedLibPath");
pub(crate) const EO_CRYPT_SHARED_REQUIRED: ExtraOptionBool = ExtraOptionBool("cryptSharedRequired");

/// Custom credential providers.
#[derive(Debug, Clone, Default, TypedBuilder)]
#[non_exhaustive]
pub struct CredentialProviders {
    /// Credential provider for MONGODB-AWS.
    #[cfg(feature = "aws-auth")]
    pub aws: Option<aws_credential_types::provider::SharedCredentialsProvider>,
}
