use std::time::Duration;

use crate::bson::Bson;

use crate::{
    coll::options::DropIndexOptions,
    error::{ErrorKind, Result},
    operation::DropIndexes as Op,
    options::WriteConcern,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Drops the index specified by `name` from this collection.
    ///
    /// `await` will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_index)]
    pub fn drop_index(&self, name: impl AsRef<str>) -> DropIndex<'_> {
        DropIndex {
            coll: CollRef::new(self),
            name: Some(name.as_ref().to_string()),
            options: None,
            session: None,
        }
    }

    /// Drops all indexes associated with this collection.
    ///
    /// `await` will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_index)]
    pub fn drop_indexes(&self) -> DropIndex<'_> {
        DropIndex {
            coll: CollRef::new(self),
            name: None,
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Drops the index specified by `name` from this collection.
    ///
    /// [`run`](DropIndex::run) will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_index, "run")]
    pub fn drop_index(&self, name: impl AsRef<str>) -> DropIndex<'_> {
        self.async_collection.drop_index(name)
    }

    /// Drops all indexes associated with this collection.
    ///
    /// [`run`](DropIndex::run) will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_index, "run")]
    pub fn drop_indexes(&self) -> DropIndex<'_> {
        self.async_collection.drop_indexes()
    }
}

/// Drop an index or indexes.  Construct with [`Collection::drop_index`] or
/// [`Collection::drop_indexes`].
#[must_use]
pub struct DropIndex<'a> {
    coll: CollRef<'a>,
    name: Option<String>,
    options: Option<DropIndexOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::DropIndexOptions)]
#[export_doc(drop_index)]
impl<'a> DropIndex<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for DropIndex<'a> {
    type Future = DropIndexFuture;

    async fn execute(self) -> Result<()> {
        if matches!(self.name.as_deref(), Some("*")) {
            return Err(ErrorKind::InvalidArgument {
                message: "Cannot pass name \"*\" to drop_index since more than one index would be \
                          dropped."
                    .to_string(),
            }
            .into());
        }
        // If there is no provided name, that means we should drop all indexes.
        let index_name = self.name.unwrap_or_else(|| "*".to_string());

        let op = Op::new(self.coll.clone(), index_name, self.options);
        self.coll.client().execute_operation(op, self.session).await
    }
}
