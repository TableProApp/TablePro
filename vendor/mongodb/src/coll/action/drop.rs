use crate::{
    action::{action_impl, DropCollection},
    error::Result,
    operation::drop_collection as op,
};

#[action_impl]
impl<'a> Action for DropCollection<'a> {
    type Future = DropCollectionFuture;

    async fn execute(mut self) -> Result<()> {
        #[cfg(feature = "in-use-encryption")]
        self.cr
            .drop_aux_collections(self.options.as_ref(), self.session.as_deref_mut())
            .await?;

        let drop = op::DropCollection::new(self.cr.clone(), self.options);
        self.cr
            .client()
            .execute_operation(drop, self.session.as_deref_mut())
            .await
    }
}

#[cfg(feature = "in-use-encryption")]
impl<T> crate::Collection<T>
where
    T: Send + Sync,
{
    #[allow(clippy::needless_option_as_deref)]
    async fn drop_aux_collections(
        &self,
        options: Option<&crate::coll::DropCollectionOptions>,
        mut session: Option<&mut crate::ClientSession>,
    ) -> Result<()> {
        use crate::bson::doc;
        use futures_util::TryStreamExt;

        // Find associated `encrypted_fields`:
        // * from options to this call
        let mut enc_fields = options.and_then(|o| o.encrypted_fields.as_ref());
        let enc_opts = self.client().auto_encryption_opts().await;
        // * from client-wide `encrypted_fields_map`:
        let client_enc_fields = enc_opts
            .as_ref()
            .and_then(|eo| eo.encrypted_fields_map.as_ref());
        if enc_fields.is_none() {
            enc_fields =
                client_enc_fields.and_then(|efm| efm.get(&format!("{}", self.namespace())));
        }
        // * from a `list_collections` call:
        let found;
        if enc_fields.is_none() && enc_opts.is_some() {
            let filter = doc! { "name": self.name() };
            let mut specs: Vec<_> = match session.as_deref_mut() {
                Some(s) => {
                    let mut cursor = self
                        .inner
                        .db
                        .list_collections()
                        .filter(filter)
                        .session(&mut *s)
                        .await?;
                    cursor.stream(s).try_collect().await?
                }
                None => {
                    self.inner
                        .db
                        .list_collections()
                        .filter(filter)
                        .await?
                        .try_collect()
                        .await?
                }
            };
            if let Some(spec) = specs.pop() {
                if let Some(enc) = spec.options.encrypted_fields {
                    found = enc;
                    enc_fields = Some(&found);
                }
            }
        }

        // Drop the collections.
        if let Some(enc_fields) = enc_fields {
            for ns in crate::client::csfle::aux_collections(&self.namespace(), enc_fields)? {
                let coll = self.client().database(&ns.db).collection(&ns.coll);
                let drop = op::DropCollection::new(coll, options.cloned());
                self.client()
                    .execute_operation(drop, session.as_deref_mut())
                    .await?;
            }
        }
        Ok(())
    }
}
