use std::time::Duration;

use crate::bson::{Bson, Document};

use crate::{
    coll::options::{DistinctOptions, Hint},
    collation::Collation,
    error::Result,
    operation::Distinct as Op,
    options::ReadConcern,
    selection_criteria::SelectionCriteria,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Finds the distinct values of the field specified by `field_name` across the collection.
    ///
    /// `await` will return d[`Result<Vec<Bson>>`].
    #[deeplink]
    #[options_doc(distinct)]
    pub fn distinct(&self, field_name: impl AsRef<str>, filter: Document) -> Distinct<'_> {
        Distinct {
            coll: CollRef::new(self),
            field_name: field_name.as_ref().to_string(),
            filter,
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
    /// Finds the distinct values of the field specified by `field_name` across the collection.
    ///
    /// [`run`](Distinct::run) will return d[`Result<Vec<Bson>>`].
    #[deeplink]
    #[options_doc(distinct, "run")]
    pub fn distinct(&self, field_name: impl AsRef<str>, filter: Document) -> Distinct<'_> {
        self.async_collection.distinct(field_name, filter)
    }
}

/// Finds the distinct values of a field.  Construct with [`Collection::distinct`].
#[must_use]
pub struct Distinct<'a> {
    coll: CollRef<'a>,
    field_name: String,
    filter: Document,
    options: Option<DistinctOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::DistinctOptions)]
#[export_doc(distinct)]
impl<'a> Distinct<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for Distinct<'a> {
    type Future = DistinctFuture;

    async fn execute(mut self) -> Result<Vec<Bson>> {
        let op = Op::new(
            self.coll.clone(),
            self.field_name,
            self.filter,
            self.options,
        );
        self.coll.client().execute_operation(op, self.session).await
    }
}
