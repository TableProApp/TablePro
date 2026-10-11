use std::time::Duration;

use crate::bson::{doc, Bson, Document};

use crate::{
    action::{action_impl, export_doc, option_setters, options_doc},
    client_encryption::{ClientEncryption, MasterKey},
    collation::Collation,
    concern::WriteConcern,
    db::options::{
        ChangeStreamPreAndPostImages,
        ClusteredIndex,
        CreateCollectionOptions,
        IndexOptionDefaults,
        TimeseriesOptions,
        ValidationAction,
        ValidationLevel,
    },
    error::{Error, Result},
    Database,
};

impl ClientEncryption {
    /// Creates a new collection with encrypted fields, automatically creating new data encryption
    /// keys when needed based on the configured [`CreateCollectionOptions::encrypted_fields`].
    ///
    /// `await` will return `(Document, Result<()>)` containing the potentially updated
    /// `encrypted_fields` along with the collection creation status, as keys may have been created
    /// even when a failure occurs.
    ///
    /// Does not affect any auto encryption settings on existing MongoClients that are already
    /// configured with auto encryption.
    #[options_doc(create_enc_coll)]
    pub fn create_encrypted_collection<'a>(
        &'a self,
        db: &'a Database,
        name: &'a str,
        master_key: MasterKey,
    ) -> CreateEncryptedCollection<'a> {
        CreateEncryptedCollection {
            client_enc: self,
            db,
            name,
            master_key,
            options: None,
        }
    }
}

/// Create a new collection with encrypted fields.  Construct with
/// [`ClientEncryption::create_encrypted_collection`].
#[must_use]
pub struct CreateEncryptedCollection<'a> {
    client_enc: &'a ClientEncryption,
    db: &'a Database,
    name: &'a str,
    master_key: MasterKey,
    options: Option<CreateCollectionOptions>,
}

#[option_setters(crate::db::options::CreateCollectionOptions)]
#[export_doc(create_enc_coll)]
impl CreateEncryptedCollection<'_> {}

#[action_impl]
impl<'a> Action for CreateEncryptedCollection<'a> {
    type Future = CreateEncryptedCollectionFuture;

    async fn execute(self) -> (Document, Result<()>) {
        let ef = match self
            .options
            .as_ref()
            .and_then(|o| o.encrypted_fields.as_ref())
        {
            Some(ef) => ef,
            None => {
                return (
                    doc! {},
                    Err(Error::invalid_argument(
                        "no encrypted_fields defined for collection",
                    )),
                );
            }
        };
        let mut ef_prime = ef.clone();
        if let Ok(fields) = ef_prime.get_array_mut("fields") {
            for f in fields {
                let f_doc = if let Some(d) = f.as_document_mut() {
                    d
                } else {
                    continue;
                };
                if f_doc.get("keyId") == Some(&Bson::Null) {
                    let d = match self
                        .client_enc
                        .create_data_key(self.master_key.clone())
                        .await
                    {
                        Ok(v) => v,
                        Err(e) => return (ef_prime, Err(e)),
                    };
                    f_doc.insert("keyId", d);
                }
            }
        }
        // Unwrap safety: the check for `encrypted_fields` at the top won't succeed if
        // `self.options` is `None`.
        let mut opts_prime = self.options.unwrap();
        opts_prime.encrypted_fields = Some(ef_prime.clone());
        (
            ef_prime,
            self.db
                .create_collection(self.name)
                .with_options(opts_prime)
                .await,
        )
    }
}
