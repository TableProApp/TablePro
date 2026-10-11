//! Support for explicit encryption.

mod create_data_key;
mod encrypt;

use std::{fmt, sync::Arc, time::Duration};

use mongocrypt::{ctx::KmsProvider, Crypt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use typed_builder::TypedBuilder;

#[cfg(feature = "bson-3")]
use crate::bson_compat::RawBsonRefExt as _;
use crate::{
    bson::{doc, spec::BinarySubtype, Binary, RawBinaryRef, RawDocumentBuf},
    client::options::TlsOptions,
    coll::options::CollectionOptions,
    error::{Error, Result},
    options::{ReadConcern, ServerAddress, WriteConcern},
    results::DeleteResult,
    BoxFuture,
    Client,
    Collection,
    Cursor,
    Namespace,
};

use super::{options::KmsProviders, state_machine::CryptExecutor};

pub use super::{client_builder::EncryptedClientBuilder, options::CredentialProviders};
pub use crate::action::csfle::encrypt::{
    EncryptKey,
    PrefixOptions,
    RangeOptions,
    StringOptions,
    SubstringOptions,
    SuffixOptions,
};

/// A handle to the key vault.  Used to create data encryption keys, and to explicitly encrypt and
/// decrypt values when auto-encryption is not an option.
pub struct ClientEncryption {
    crypt: Crypt,
    exec: CryptExecutor,
    key_vault: Collection<RawDocumentBuf>,
}

impl ClientEncryption {
    /// Initialize a new `ClientEncryption`.
    ///
    /// ```no_run
    /// # use mongocrypt::ctx::KmsProvider;
    /// # use mongodb::{bson::doc, client_encryption::ClientEncryption, error::Result};
    /// # fn func() -> Result<()> {
    /// # let kv_client = todo!();
    /// # let kv_namespace = todo!();
    /// # let local_key = doc! { };
    /// let enc = ClientEncryption::new(
    ///     kv_client,
    ///     kv_namespace,
    ///     [
    ///         (KmsProvider::local(), doc! { "key": local_key }, None),
    ///         (KmsProvider::kmip(), doc! { "endpoint": "localhost:5698" }, None),
    ///     ]
    /// )?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn new(
        key_vault_client: Client,
        key_vault_namespace: Namespace,
        kms_providers: impl IntoIterator<
            Item = (KmsProvider, crate::bson::Document, Option<TlsOptions>),
        >,
    ) -> Result<Self> {
        Self::builder(key_vault_client, key_vault_namespace, kms_providers).build()
    }

    /// Initialize a builder to construct a [`ClientEncryption`]. Methods on
    /// [`ClientEncryptionBuilder`] can be chained to set options.
    ///
    /// ```no_run
    /// # use mongocrypt::ctx::KmsProvider;
    /// # use mongodb::{bson::doc, client_encryption::ClientEncryption, error::Result};
    /// # fn func() -> Result<()> {
    /// # let kv_client = todo!();
    /// # let kv_namespace = todo!();
    /// # let local_key = doc! { };
    /// let enc = ClientEncryption::builder(
    ///     kv_client,
    ///     kv_namespace,
    ///     [
    ///         (KmsProvider::local(), doc! { "key": local_key }, None),
    ///         (KmsProvider::kmip(), doc! { "endpoint": "localhost:5698" }, None),
    ///     ]
    /// )
    /// .build()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn builder(
        key_vault_client: Client,
        key_vault_namespace: Namespace,
        kms_providers: impl IntoIterator<
            Item = (KmsProvider, crate::bson::Document, Option<TlsOptions>),
        >,
    ) -> ClientEncryptionBuilder {
        ClientEncryptionBuilder {
            key_vault_client,
            key_vault_namespace,
            kms_providers: kms_providers.into_iter().collect(),
            key_cache_expiration: None,
            kms_connect_callback: None,
            credential_providers: None,
        }
    }

    // pub async fn rewrap_many_data_key(&self, _filter: Document, _opts: impl
    // Into<Option<RewrapManyDataKeyOptions>>) -> Result<RewrapManyDataKeyResult> {
    // todo!("RUST-1441") }

    /// Removes the key document with the given UUID (BSON binary subtype 0x04) from the key vault
    /// collection. Returns the result of the internal deleteOne() operation on the key vault
    /// collection.
    pub async fn delete_key(&self, id: &Binary) -> Result<DeleteResult> {
        self.key_vault.delete_one(doc! { "_id": id }).await
    }

    /// Finds a single key document with the given UUID (BSON binary subtype 0x04).
    /// Returns the result of the internal find() operation on the key vault collection.
    pub async fn get_key(&self, id: &Binary) -> Result<Option<RawDocumentBuf>> {
        self.key_vault.find_one(doc! { "_id": id }).await
    }

    /// Finds all documents in the key vault collection.
    /// Returns the result of the internal find() operation on the key vault collection.
    pub async fn get_keys(&self) -> Result<Cursor<RawDocumentBuf>> {
        self.key_vault.find(doc! {}).await
    }

    /// Adds a keyAltName to the keyAltNames array of the key document in the key vault collection
    /// with the given UUID (BSON binary subtype 0x04). Returns the previous version of the key
    /// document.
    pub async fn add_key_alt_name(
        &self,
        id: &Binary,
        key_alt_name: &str,
    ) -> Result<Option<RawDocumentBuf>> {
        self.key_vault
            .find_one_and_update(
                doc! { "_id": id },
                doc! { "$addToSet": { "keyAltNames": key_alt_name } },
            )
            .await
    }

    /// Removes a keyAltName from the keyAltNames array of the key document in the key vault
    /// collection with the given UUID (BSON binary subtype 0x04). Returns the previous version
    /// of the key document.
    pub async fn remove_key_alt_name(
        &self,
        id: &Binary,
        key_alt_name: &str,
    ) -> Result<Option<RawDocumentBuf>> {
        let update = doc! {
            "$set": {
                "keyAltNames": {
                    "$cond": [
                        { "$eq": ["$keyAltNames", [key_alt_name]] },
                        "$$REMOVE",
                        {
                            "$filter": {
                                "input": "$keyAltNames",
                                "cond": { "$ne": ["$$this", key_alt_name] },
                            }
                        }
                    ]
                }
            }
        };
        self.key_vault
            .find_one_and_update(doc! { "_id": id }, vec![update])
            .await
    }

    /// Returns a key document in the key vault collection with the given keyAltName.
    pub async fn get_key_by_alt_name(
        &self,
        key_alt_name: impl AsRef<str>,
    ) -> Result<Option<RawDocumentBuf>> {
        self.key_vault
            .find_one(doc! { "keyAltNames": key_alt_name.as_ref() })
            .await
    }

    /// Decrypts an encrypted value (BSON binary of subtype 6).
    /// Returns the original BSON value.
    pub async fn decrypt(&self, value: RawBinaryRef<'_>) -> Result<crate::bson::RawBson> {
        if value.subtype != BinarySubtype::Encrypted {
            return Err(Error::invalid_argument(format!(
                "Invalid binary subtype for decrypt: expected {:?}, got {:?}",
                BinarySubtype::Encrypted,
                value.subtype
            )));
        }
        let ctx = self
            .crypt
            .ctx_builder()
            .build_explicit_decrypt(value.bytes)?;
        let result = self.exec.run_ctx(ctx, None).await?;
        Ok(result
            .get("v")?
            .ok_or_else(|| Error::internal("invalid decryption result"))?
            .to_raw_bson())
    }
}

/// Builder for constructing a [`ClientEncryption`]. Construct by calling
/// [`ClientEncryption::builder`].
pub struct ClientEncryptionBuilder {
    key_vault_client: Client,
    key_vault_namespace: Namespace,
    kms_providers: Vec<(KmsProvider, crate::bson::Document, Option<TlsOptions>)>,
    key_cache_expiration: Option<Duration>,
    kms_connect_callback: Option<KmsConnectCallback>,
    credential_providers: Option<CredentialProviders>,
}

impl ClientEncryptionBuilder {
    /// Set the duration of time after which the data encryption key cache should expire. Defaults
    /// to 60 seconds if unset.
    pub fn key_cache_expiration(mut self, expiration: impl Into<Option<Duration>>) -> Self {
        self.key_cache_expiration = expiration.into();
        self
    }

    /// Set a callback used to establish connections to KMS providers. See the documentation for
    /// [`KmsConnectCallback`] for more details.
    pub fn kms_connect_callback(mut self, callback: impl Into<Option<KmsConnectCallback>>) -> Self {
        self.kms_connect_callback = callback.into();
        self
    }

    /// Specify custom credential providers.
    pub fn credential_providers(
        mut self,
        providers: impl Into<Option<CredentialProviders>>,
    ) -> Self {
        self.credential_providers = providers.into();
        self
    }

    /// Build the [`ClientEncryption`].
    pub fn build(self) -> Result<ClientEncryption> {
        let kms_providers = KmsProviders::new(self.kms_providers)?;
        kms_providers.validate_credential_providers(&self.credential_providers)?;

        let mut crypt_builder = Crypt::builder()
            .kms_providers(&kms_providers.credentials_doc()?)?
            .use_need_kms_credentials_state()
            .use_range_v2()?
            .retry_kms(true)?;
        if let Some(key_cache_expiration) = self.key_cache_expiration {
            let expiration_ms: u64 = key_cache_expiration.as_millis().try_into().map_err(|_| {
                Error::invalid_argument(format!(
                    "key_cache_expiration must not exceed {} milliseconds, got {:?}",
                    u64::MAX,
                    key_cache_expiration
                ))
            })?;
            crypt_builder = crypt_builder.key_cache_expiration(expiration_ms)?;
        }
        let crypt = crypt_builder.build()?;

        let exec = CryptExecutor::new_explicit(
            self.key_vault_client.weak(),
            self.key_vault_namespace.clone(),
            kms_providers,
            self.kms_connect_callback,
            self.credential_providers,
        )?;
        let key_vault = self
            .key_vault_client
            .database(&self.key_vault_namespace.db)
            .collection_with_options(
                &self.key_vault_namespace.coll,
                CollectionOptions::builder()
                    .write_concern(WriteConcern::majority())
                    .read_concern(ReadConcern::majority())
                    .build(),
            );

        Ok(ClientEncryption {
            crypt,
            exec,
            key_vault,
        })
    }
}

/// A KMS-specific key used to encrypt data keys.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
#[non_exhaustive]
#[allow(missing_docs)]
pub enum MasterKey {
    Aws(AwsMasterKey),
    Azure(AzureMasterKey),
    Gcp(GcpMasterKey),
    Kmip(KmipMasterKey),
    Local(LocalMasterKey),
}

/// An AWS master key.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Serialize, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct AwsMasterKey {
    /// The name for the key. The value for this field must be the same as the corresponding
    /// [`KmsProvider`](mongocrypt::ctx::KmsProvider)'s name.
    #[serde(skip)]
    pub name: Option<String>,

    /// The region.
    pub region: String,

    /// The Amazon Resource Name (ARN) to the AWS customer master key (CMK).
    pub key: String,

    /// An alternate host identifier to send KMS requests to. May include port number. Defaults to
    /// "kms.\<region\>.amazonaws.com".
    pub endpoint: Option<String>,
}

impl From<AwsMasterKey> for MasterKey {
    fn from(aws_master_key: AwsMasterKey) -> Self {
        Self::Aws(aws_master_key)
    }
}

/// An Azure master key.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Serialize, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct AzureMasterKey {
    /// The name for the key. The value for this field must be the same as the corresponding
    /// [`KmsProvider`](mongocrypt::ctx::KmsProvider)'s name.
    #[serde(skip)]
    pub name: Option<String>,

    /// Host with optional port. Example: "example.vault.azure.net".
    pub key_vault_endpoint: String,

    /// The key name.
    pub key_name: String,

    /// A specific version of the named key, defaults to using the key's primary version.
    pub key_version: Option<String>,
}

impl From<AzureMasterKey> for MasterKey {
    fn from(azure_master_key: AzureMasterKey) -> Self {
        Self::Azure(azure_master_key)
    }
}

/// A GCP master key.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Serialize, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct GcpMasterKey {
    /// The name for the key. The value for this field must be the same as the corresponding
    /// [`KmsProvider`](mongocrypt::ctx::KmsProvider)'s name.
    #[serde(skip)]
    pub name: Option<String>,

    /// The project ID.
    pub project_id: String,

    /// The location.
    pub location: String,

    /// The key ring.
    pub key_ring: String,

    /// The key name.
    pub key_name: String,

    /// A specific version of the named key. Defaults to using the key's primary version.
    pub key_version: Option<String>,

    /// Host with optional port. Defaults to "cloudkms.googleapis.com".
    pub endpoint: Option<String>,
}

impl From<GcpMasterKey> for MasterKey {
    fn from(gcp_master_key: GcpMasterKey) -> Self {
        Self::Gcp(gcp_master_key)
    }
}

/// A local master key.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Serialize, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct LocalMasterKey {
    /// The name for the key. The value for this field must be the same as the corresponding
    /// [`KmsProvider`](mongocrypt::ctx::KmsProvider)'s name.
    #[serde(skip)]
    pub name: Option<String>,
}

impl From<LocalMasterKey> for MasterKey {
    fn from(local_master_key: LocalMasterKey) -> Self {
        Self::Local(local_master_key)
    }
}

/// A KMIP master key.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Serialize, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct KmipMasterKey {
    /// The name for the key. The value for this field must be the same as the corresponding
    /// [`KmsProvider`](mongocrypt::ctx::KmsProvider)'s name.
    #[serde(skip)]
    pub name: Option<String>,

    /// The KMIP Unique Identifier to a 96 byte KMIP Secret Data managed object. If this field is
    /// not specified, the driver creates a random 96 byte KMIP Secret Data managed object.
    pub key_id: Option<String>,

    /// If true (recommended), the KMIP server must decrypt this key. Defaults to false.
    pub delegated: Option<bool>,

    /// Host with optional port.
    pub endpoint: Option<String>,
}

impl From<KmipMasterKey> for MasterKey {
    fn from(kmip_master_key: KmipMasterKey) -> Self {
        Self::Kmip(kmip_master_key)
    }
}

impl MasterKey {
    /// Returns the `KmsProvider` associated with this key.
    pub fn provider(&self) -> KmsProvider {
        let (provider, name) = match self {
            MasterKey::Aws(AwsMasterKey { name, .. }) => (KmsProvider::aws(), name.clone()),
            MasterKey::Azure(AzureMasterKey { name, .. }) => (KmsProvider::azure(), name.clone()),
            MasterKey::Gcp(GcpMasterKey { name, .. }) => (KmsProvider::gcp(), name.clone()),
            MasterKey::Kmip(KmipMasterKey { name, .. }) => (KmsProvider::kmip(), name.clone()),
            MasterKey::Local(LocalMasterKey { name, .. }) => (KmsProvider::local(), name.clone()),
        };
        if let Some(name) = name {
            provider.with_name(name)
        } else {
            provider
        }
    }
}

// #[non_exhaustive]
// pub struct RewrapManyDataKeyOptions {
// pub provider: KmsProvider,
// pub master_key: Option<Document>,
// }
//
//
// #[non_exhaustive]
// pub struct RewrapManyDataKeyResult {
// pub bulk_write_result: Option<BulkWriteResult>,
// }

/// A trait representing a stream connected to a KMS provider. This trait is automatically
/// implemented for all types that implement [`AsyncRead`], [`AsyncWrite`], `Send`, and `Unpin`.
pub trait KmsStream: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> KmsStream for T {}

/// The callback to use to connect to KMS providers.
///
/// A `KmsConnectCallback` accepts a [`ServerAddress`] representing the address of the KMS host and
/// returns any type that implements the [`KmsStream`] trait.
///
/// The driver wraps the returned [`KmsStream`] with TLS using the TLS options configured for the
/// KMS provider.
///
/// See [`KmsConnectCallback::new`] for details on how to construct this type.
#[derive(Clone)]
#[non_exhaustive]
pub struct KmsConnectCallback(
    #[allow(clippy::type_complexity)]
    Arc<dyn Fn(ServerAddress) -> BoxFuture<'static, Result<Box<dyn KmsStream>>> + Send + Sync>,
);

impl KmsConnectCallback {
    /// Create a new KMS connect callback.
    ///
    /// Due to limitations in the Rust compiler, this type cannot be constructed directly from an
    /// async closure. Instead, this function accepts a sync closure that returns a [`BoxFuture`]
    /// containing the logic to establish the KMS stream.
    ///
    /// ```no_run
    /// # use mongodb::{error::Result, options::ServerAddress};
    /// # use tokio::net::TcpStream;
    /// # async fn connect_through_proxy(address: ServerAddress) -> Result<TcpStream> {
    /// #     todo!()
    /// # }
    /// use futures::FutureExt;
    /// use mongodb::client_encryption::KmsConnectCallback;
    /// let callback = KmsConnectCallback::new(move |server_address| {
    ///     async move { connect_through_proxy(server_address).await }.boxed()
    /// });
    /// ```
    ///
    /// The callback returns this crate's [`Result`] type. Where possible, errors from the callback
    /// should be converted directly into [`Error`] using the `?` operator (e.g. `std::io::Error`s).
    /// The [`Error::custom`] constructor can be used for error types that cannot be converted.
    pub fn new<F, S>(callback: F) -> Self
    where
        F: Fn(ServerAddress) -> BoxFuture<'static, Result<S>> + Send + Sync + 'static,
        S: KmsStream + 'static,
    {
        Self(Arc::new(move |address| {
            let future = callback(address);
            Box::pin(async move { Ok(Box::new(future.await?) as Box<dyn KmsStream>) })
        }))
    }

    pub(crate) fn connect(
        &self,
        address: ServerAddress,
    ) -> BoxFuture<'static, Result<Box<dyn KmsStream>>> {
        (self.0)(address)
    }
}

impl fmt::Debug for KmsConnectCallback {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KmsConnectCallback").finish()
    }
}
