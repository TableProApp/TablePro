use crate::bson::{doc, Binary};
use mongocrypt::ctx::{Ctx, KmsProvider};

use crate::{
    action::{
        action_impl,
        csfle::{CreateDataKey, DataKeyOptions},
    },
    error::{Error, Result},
};

use super::{ClientEncryption, MasterKey};

#[action_impl]
impl<'a> Action for CreateDataKey<'a> {
    type Future = CreateDataKeyFuture;

    async fn execute(self) -> Result<Binary> {
        #[allow(unused_mut)]
        let mut provider = self.master_key.provider();
        #[cfg(test)]
        if let Some(tp) = self.test_kms_provider {
            provider = tp;
        }
        let ctx = self
            .client_enc
            .create_data_key_ctx(provider, self.master_key, self.options)?;
        let data_key = self.client_enc.exec.run_ctx(ctx, None).await?;
        self.client_enc.key_vault.insert_one(&data_key).await?;
        let bin_ref = data_key
            .get_binary("_id")
            .map_err(|e| Error::internal(format!("invalid data key id: {e}")))?;
        Ok(bin_ref.to_binary())
    }
}

impl ClientEncryption {
    fn create_data_key_ctx(
        &self,
        kms_provider: KmsProvider,
        master_key: MasterKey,
        opts: Option<DataKeyOptions>,
    ) -> Result<Ctx> {
        let mut builder = self.crypt.ctx_builder();
        let mut key_doc = doc! { "provider": kms_provider.as_string() };
        if !matches!(master_key, MasterKey::Local(_)) {
            let master_doc = crate::bson_compat::serialize_to_document(&master_key)?;
            key_doc.extend(master_doc);
        }
        if let Some(opts) = opts {
            if let Some(alt_names) = &opts.key_alt_names {
                for name in alt_names {
                    builder = builder.key_alt_name(name)?;
                }
            }
            if let Some(material) = &opts.key_material {
                builder = builder.key_material(material)?;
            }
        }
        builder = builder.key_encryption_key(&key_doc)?;
        Ok(builder.build_datakey()?)
    }
}
