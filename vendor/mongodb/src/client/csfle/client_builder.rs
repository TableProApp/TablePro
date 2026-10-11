use std::time::Duration;

use crate::{
    bson::Document,
    client::csfle::options::CredentialProviders,
    error::Result,
    options::ClientOptions,
    Client,
};

use super::{client_encryption::KmsConnectCallback, options::AutoEncryptionOptions};

/// A builder for constructing a `Client` with auto-encryption enabled.
///
/// ```no_run
/// # use mongocrypt::ctx::KmsProvider;
/// # use mongodb::{Client, bson::{self, doc}, error::Result};
/// # async fn func() -> Result<()> {
/// # let client_options = todo!();
/// # let key_vault_namespace = todo!();
/// # let key_vault_client: Client = todo!();
/// # let local_key: bson::Binary = todo!();
/// let encrypted_client = Client::encrypted_builder(
///     client_options,
///     key_vault_namespace,
///     [(KmsProvider::local(), doc! { "key": local_key }, None)],
/// )?
/// .key_vault_client(key_vault_client)
/// .build()
/// .await?;
/// # Ok(())
/// # }
/// ```
pub struct EncryptedClientBuilder {
    client_options: ClientOptions,
    enc_opts: AutoEncryptionOptions,
}

impl EncryptedClientBuilder {
    pub(crate) fn new(client_options: ClientOptions, enc_opts: AutoEncryptionOptions) -> Self {
        EncryptedClientBuilder {
            client_options,
            enc_opts,
        }
    }

    /// Set the client used for data key queries.  Will default to an internal client if not set.
    pub fn key_vault_client(mut self, client: impl Into<Option<Client>>) -> Self {
        self.enc_opts.key_vault_client = client.into();
        self
    }

    /// Specify a JSONSchema locally.
    ///
    /// Supplying a `schema_map` provides more security than relying on JSON Schemas obtained from
    /// the server. It protects against a malicious server advertising a false JSON Schema, which
    /// could trick the client into sending unencrypted data that should be encrypted.
    ///
    /// Schemas supplied in the `schema_map` only apply to configuring automatic encryption for
    /// client side encryption. Other validation rules in the JSON schema will not be enforced by
    /// the driver and will result in an error.
    pub fn schema_map(
        mut self,
        map: impl IntoIterator<Item = (impl Into<String>, Document)>,
    ) -> Self {
        self.enc_opts.schema_map = Some(map.into_iter().map(|(is, d)| (is.into(), d)).collect());
        self
    }

    /// Disable automatic encryption and do not spawn mongocryptd.  Defaults to false.
    pub fn bypass_auto_encryption(mut self, bypass: impl Into<Option<bool>>) -> Self {
        self.enc_opts.bypass_auto_encryption = bypass.into();
        self
    }

    /// Set options related to mongocryptd.
    pub fn extra_options(mut self, extra_opts: impl Into<Option<Document>>) -> Self {
        self.enc_opts.extra_options = extra_opts.into();
        self
    }

    /// Maps namespace to encrypted fields.
    ///
    /// Supplying an `encrypted_fields_map` provides more security than relying on an
    /// encryptedFields obtained from the server. It protects against a malicious server
    /// advertising a false encryptedFields.
    pub fn encrypted_fields_map(
        mut self,
        map: impl IntoIterator<Item = (impl Into<String>, Document)>,
    ) -> Self {
        self.enc_opts.encrypted_fields_map =
            Some(map.into_iter().map(|(is, d)| (is.into(), d)).collect());
        self
    }

    /// Disable serverside processing of encrypted indexed fields, allowing use of explicit
    /// encryption with queryable encryption.
    pub fn bypass_query_analysis(mut self, bypass: impl Into<Option<bool>>) -> Self {
        self.enc_opts.bypass_query_analysis = bypass.into();
        self
    }

    /// Disable loading crypt_shared.
    #[cfg(test)]
    pub(crate) fn disable_crypt_shared(mut self, disable: bool) -> Self {
        self.enc_opts.disable_crypt_shared = Some(disable);
        self
    }

    /// Set the duration of time after which the data encryption key cache should expire. Defaults
    /// to 60 seconds if unset.
    pub fn key_cache_expiration(mut self, expiration: impl Into<Option<Duration>>) -> Self {
        self.enc_opts.key_cache_expiration = expiration.into();
        self
    }

    /// Set a callback used to establish connections to KMS providers. See the documentation for
    /// [`KmsConnectCallback`] for more details.
    pub fn kms_connect_callback(mut self, callback: impl Into<Option<KmsConnectCallback>>) -> Self {
        self.enc_opts.kms_connect_callback = callback.into();
        self
    }

    /// Specify custom credential providers.
    pub fn credential_providers(
        mut self,
        providers: impl Into<Option<CredentialProviders>>,
    ) -> Self {
        self.enc_opts.credential_providers = providers.into();
        self
    }

    /// Constructs a new `Client` using automatic encryption.  May perform DNS lookups and/or spawn
    /// mongocryptd as part of `Client` initialization.
    pub async fn build(self) -> Result<Client> {
        let client = Client::with_options(self.client_options)?;
        client.init_csfle(self.enc_opts).await?;
        Ok(client)
    }
}
