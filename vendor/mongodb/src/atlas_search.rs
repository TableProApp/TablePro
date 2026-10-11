//! Helpers for building Atlas Search aggregation pipelines.  Use one of the constructor functions
//! and chain optional value setters, and then convert to a pipeline stage [`Document`] via
//! [`into_stage`](SearchOperator::into_stage).
//!
//! ```no_run
//! # async fn wrapper() -> mongodb::error::Result<()> {
//! # use mongodb::{Collection, bson::{Document, doc}};
//! # let collection: Collection<Document> = todo!();
//! use mongodb::atlas_search;
//! let cursor = collection.aggregate(vec![
//!     atlas_search::autocomplete("title", "pre")
//!         .fuzzy(doc! { "maxEdits": 1, "prefixLength": 1, "maxExpansions": 256 })
//!         .into_stage(),
//!     doc! {
//!         "$limit": 10,
//!    },
//!    doc! {
//!        "$project": {
//!            "_id": 0,
//!            "title": 1,
//!         }
//!    },
//! ]).await?;
//! # Ok(())
//! # }
mod gen;

pub use gen::*;

use std::marker::PhantomData;

use crate::bson::{doc, Bson, DateTime, Document};
use mongodb_internal_macros::{export_doc, options_doc};

/// A helper to build the aggregation stage for Atlas Search.
pub struct SearchOperator<T> {
    pub(crate) name: &'static str,
    pub(crate) spec: Document,
    _t: PhantomData<T>,
}

impl<T> SearchOperator<T> {
    fn new(name: &'static str, spec: Document) -> Self {
        Self {
            name,
            spec,
            _t: PhantomData,
        }
    }

    /// Finalize this search operator as a `$search` aggregation stage document.
    pub fn into_stage(self) -> Document {
        search(self).into_stage()
    }

    /// Finalize this search operator as a `$searchMeta` aggregation stage document.
    pub fn into_stage_meta(self) -> Document {
        search_meta(self).into_stage()
    }

    /// Erase the type of this builder.  Not typically needed, but can be useful to include builders
    /// of different types in a single `Vec`:
    /// ```no_run
    /// # async fn wrapper() -> mongodb::error::Result<()> {
    /// # use mongodb::{Collection, bson::{Document, doc}};
    /// # let collection: Collection<Document> = todo!();
    /// use mongodb::atlas_search;
    /// let cursor = collection.aggregate(vec![
    ///     atlas_search::compound()
    ///         .must(vec![
    ///             atlas_search::text("description", "varieties").unit(),
    ///             atlas_search::compound()
    ///                 .should(atlas_search::text("description", "Fuji"))
    ///                 .unit(),
    ///         ])
    ///         .into_stage(),
    /// ]).await?;
    /// # }
    /// ```
    pub fn unit(self) -> SearchOperator<()> {
        SearchOperator {
            name: self.name,
            spec: self.spec,
            _t: PhantomData,
        }
    }
}

/// Finalize a search operator as a pending `$search` aggregation stage, allowing
/// options to be set.
/// ```no_run
/// # async fn wrapper() -> mongodb::error::Result<()> {
/// # use mongodb::{Collection, bson::{Document, doc}};
/// # let collection: Collection<Document> = todo!();
/// use mongodb::atlas_search::{autocomplete, search};
/// let cursor = collection.aggregate(vec![
///     search(
///         autocomplete("title", "pre")
///             .fuzzy(doc! { "maxEdits": 1, "prefixLength": 1, "maxExpansions": 256 })
///     )
///     .index("movies")
///     .into_stage(),
///     doc! {
///         "$limit": 10,
///     },
///     doc! {
///         "$project": {
///             "_id": 0,
///             "title": 1,
///          }
///     },
/// ]).await?;
/// # Ok(())
/// # }
/// ```
#[options_doc(atlas_search, "into_stage")]
pub fn search<T>(op: SearchOperator<T>) -> AtlasSearch {
    AtlasSearch {
        stage: doc! { op.name: op.spec },
    }
}

/// A pending `$search` aggregation stage.  Construct with [`search`].
pub struct AtlasSearch {
    stage: Document,
}

#[export_doc(atlas_search)]
impl AtlasSearch {
    /// Parallelize search across segments on dedicated search nodes.
    pub fn concurrent(mut self, value: bool) -> Self {
        self.stage.insert("concurrent", value);
        self
    }

    /// Document that specifies the count options for retrieving a count of the results.
    pub fn count(mut self, value: Document) -> Self {
        self.stage.insert("count", value);
        self
    }

    /// Document that specifies the highlighting options for displaying search terms in their
    /// original context.
    pub fn highlight(mut self, value: Document) -> Self {
        self.stage.insert("highlight", value);
        self
    }

    /// Name of the Atlas Search index to use.
    pub fn index(mut self, value: impl Into<String>) -> Self {
        self.stage.insert("index", value.into());
        self
    }

    /// Flag that specifies whether to perform a full document lookup on the backend database or
    /// return only stored source fields directly from Atlas Search.
    pub fn return_stored_source(mut self, value: bool) -> Self {
        self.stage.insert("returnStoredSource", value);
        self
    }

    /// Reference point for retrieving results.
    pub fn search_after(mut self, value: impl Into<String>) -> Self {
        self.stage.insert("searchAfter", value.into());
        self
    }

    /// Reference point for retrieving results.
    pub fn search_before(mut self, value: impl Into<String>) -> Self {
        self.stage.insert("searchBefore", value.into());
        self
    }

    /// Flag that specifies whether to retrieve a detailed breakdown of the score for the documents
    /// in the results.
    pub fn score_details(mut self, value: bool) -> Self {
        self.stage.insert("scoreDetails", value);
        self
    }

    /// Document that specifies the fields to sort the Atlas Search results by in ascending or
    /// descending order.
    pub fn sort(mut self, value: Document) -> Self {
        self.stage.insert("sort", value);
        self
    }

    /// Convert to an aggregation stage document.
    pub fn into_stage(self) -> Document {
        doc! { "$search": self.stage }
    }
}

/// Finalize a search operator as a pending `$searchMeta` aggregation stage, allowing
/// options to be set.
/// ```no_run
/// # async fn wrapper() -> mongodb::error::Result<()> {
/// # use mongodb::{Collection, bson::{DateTime, Document, doc}};
/// # let collection: Collection<Document> = todo!();
/// # let start: DateTime = todo!();
/// # let end: DateTime = todo!();
/// use mongodb::atlas_search::{facet, range, search_meta};
/// let cursor = collection.aggregate(vec![
///     search_meta(
///         facet(doc! {
///             "directorsFacet": facet::string("directors").num_buckets(7),
///             "yearFacet": facet::number("year", [2000, 2005, 2010, 2015]),
///         })
///        .operator(range("released").gte(start).lte(end))
///     )
///     .index("movies")
///     .into_stage(),
///     doc! {
///         "$limit": 10,
///     },
/// ]).await?;
/// # Ok(())
/// # }
/// ```
#[options_doc(atlas_search_meta, "into_stage")]
pub fn search_meta<T>(op: SearchOperator<T>) -> AtlasSearchMeta {
    AtlasSearchMeta {
        stage: doc! { op.name: op.spec },
    }
}

/// A pending `$searchMeta` aggregation stage.  Construct with [`search_meta`].
pub struct AtlasSearchMeta {
    stage: Document,
}

#[export_doc(atlas_search_meta)]
impl AtlasSearchMeta {
    /// Document that specifies the count options for retrieving a count of the results.
    pub fn count(mut self, value: Document) -> Self {
        self.stage.insert("count", value);
        self
    }

    /// Name of the Atlas Search index to use.
    pub fn index(mut self, value: impl Into<String>) -> Self {
        self.stage.insert("index", value.into());
        self
    }

    /// Convert to an aggregation stage document.
    pub fn into_stage(self) -> Document {
        doc! { "$searchMeta": self.stage }
    }
}

impl<T> IntoIterator for SearchOperator<T> {
    type Item = SearchOperator<T>;

    type IntoIter = std::iter::Once<SearchOperator<T>>;

    fn into_iter(self) -> Self::IntoIter {
        std::iter::once(self)
    }
}

/// Order in which to search for tokens.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum TokenOrder {
    /// Indicates tokens in the query can appear in any order in the documents.
    Any,
    /// Indicates tokens in the query must appear adjacent to each other or in the order specified
    /// in the query in the documents.
    Sequential,
    /// Fallback for future compatibility.
    Other(String),
}

impl TokenOrder {
    fn name(&self) -> &str {
        match self {
            Self::Any => "any",
            Self::Sequential => "sequential",
            Self::Other(s) => s.as_str(),
        }
    }
}

/// Criteria to use to match the terms in the query.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum MatchCriteria {
    /// Return documents that contain any of the terms from the query field.
    Any,
    /// Only return documents that contain all of the terms from the query field.
    All,
    /// Fallback for future compatibility.
    Other(String),
}

impl MatchCriteria {
    fn name(&self) -> &str {
        match self {
            Self::Any => "any",
            Self::All => "all",
            Self::Other(s) => s.as_str(),
        }
    }
}

mod private {
    use crate::bson::{doc, Bson};

    /// An Atlas Search operator parameter that can accept multiple types.
    pub trait Parameter {
        fn to_bson(self) -> Bson;
    }

    impl<T: Into<Bson>> Parameter for T {
        fn to_bson(self) -> Bson {
            self.into()
        }
    }

    impl<T> Parameter for super::SearchOperator<T> {
        fn to_bson(self) -> Bson {
            Bson::Document(doc! { self.name: self.spec })
        }
    }
}

/// An Atlas Search operator parameter that can be either a string or array of strings.
pub trait StringOrArray: private::Parameter {}
impl StringOrArray for &str {}
impl StringOrArray for String {}
#[cfg(feature = "bson-3")]
impl<const N: usize> StringOrArray for [&str; N] {}
impl StringOrArray for &[&str] {}
impl StringOrArray for &[String] {}

/// An Atlas Search operator parameter that is itself a search operator.
pub trait SearchOperatorParam: private::Parameter {}
impl<T> SearchOperatorParam for SearchOperator<T> {}
impl SearchOperatorParam for Document {}

/// Facet definitions.  These can be used when constructing a facet definition doc:
/// ```
/// # use mongodb::bson::doc;
/// use mongodb::atlas_search::facet;
/// let search = facet(doc! {
///   "directorsFacet": facet::string("directors").num_buckets(7),
///   "yearFacet": facet::number("year", [2000, 2005, 2010, 2015]),
/// });
/// ```
pub mod facet {
    use crate::bson::{doc, Bson, Document};
    use std::marker::PhantomData;

    /// A facet definition; see the [facet docs](https://www.mongodb.com/docs/atlas/atlas-search/facet/) for more details.
    pub struct Facet<T> {
        inner: Document,
        _t: PhantomData<T>,
    }

    impl<T> From<Facet<T>> for Bson {
        fn from(value: Facet<T>) -> Self {
            Bson::Document(value.inner)
        }
    }

    /// A string facet.  Construct with [`facet::string`](string).
    pub struct String;
    /// String facets allow you to narrow down Atlas Search results based on the most frequent
    /// string values in the specified string field.
    pub fn string(path: impl AsRef<str>) -> Facet<String> {
        Facet {
            inner: doc! {
                "type": "string",
                "path": path.as_ref(),
            },
            _t: PhantomData,
        }
    }
    impl Facet<String> {
        /// Maximum number of facet categories to return in the results. Value must be less than or
        /// equal to 1000.
        pub fn num_buckets(mut self, num: i32) -> Self {
            self.inner.insert("numBuckets", num);
            self
        }
    }

    /// A number facet.  Construct with [`facet::number`](number).
    pub struct Number;
    /// Numeric facets allow you to determine the frequency of numeric values in your search results
    /// by breaking the results into separate ranges of numbers.
    pub fn number(
        path: impl AsRef<str>,
        boundaries: impl IntoIterator<Item = impl Into<Bson>>,
    ) -> Facet<Number> {
        Facet {
            inner: doc! {
                "type": "number",
                "path": path.as_ref(),
                "boundaries": boundaries.into_iter().map(Into::into).collect::<Vec<_>>(),
            },
            _t: PhantomData,
        }
    }
    impl Facet<Number> {
        /// Name of an additional bucket that counts documents returned from the operator that do
        /// not fall within the specified boundaries.
        pub fn default_bucket(mut self, bucket: impl AsRef<str>) -> Self {
            self.inner.insert("default", bucket.as_ref());
            self
        }
    }

    /// A date facet.  Construct with [`facet::date`](date).
    pub struct Date;
    /// Date facets allow you to narrow down search results based on a date.
    pub fn date(
        path: impl AsRef<str>,
        boundaries: impl IntoIterator<Item = crate::bson::DateTime>,
    ) -> Facet<Date> {
        Facet {
            inner: doc! {
                "type": "date",
                "path": path.as_ref(),
                "boundaries": boundaries.into_iter().collect::<Vec<_>>(),
            },
            _t: PhantomData,
        }
    }
    impl Facet<Date> {
        /// Name of an additional bucket that counts documents returned from the operator that do
        /// not fall within the specified boundaries.
        pub fn default_bucket(mut self, bucket: impl AsRef<str>) -> Self {
            self.inner.insert("default", bucket.as_ref());
            self
        }
    }
}

/// Relation of the query shape geometry to the indexed field geometry.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum Relation {
    /// Indicates that the indexed geometry contains the query geometry.
    Contains,
    /// Indicates that both the query and indexed geometries have nothing in common.
    Disjoint,
    /// Indicates that both the query and indexed geometries intersect.
    Intersects,
    /// Indicates that the indexed geometry is within the query geometry. You can't use within with
    /// LineString or Point.
    Within,
    /// Fallback for future compatibility.
    Other(String),
}

impl Relation {
    fn name(&self) -> &str {
        match self {
            Self::Contains => "contains",
            Self::Disjoint => "disjoint",
            Self::Intersects => "intersects",
            Self::Within => "within",
            Self::Other(s) => s,
        }
    }
}

/// An Atlas Search operator parameter that can be either a document or array of documents.
pub trait DocumentOrArray: private::Parameter {}
impl DocumentOrArray for Document {}
#[cfg(feature = "bson-3")]
impl<const N: usize> DocumentOrArray for [Document; N] {}
impl DocumentOrArray for &[Document] {}

macro_rules! numeric {
    ($trait:ty) => {
        impl $trait for i32 {}
        impl $trait for i64 {}
        impl $trait for u32 {}
        impl $trait for f32 {}
        impl $trait for f64 {}
    };
}

/// An Atlas Search operator parameter that can be a date, number, or GeoJSON point.
pub trait NearOrigin: private::Parameter {}
impl NearOrigin for DateTime {}
impl NearOrigin for Document {}
numeric! { NearOrigin }

/// An Atlas Search operator parameter that can be any BSON numeric type.
pub trait BsonNumber: private::Parameter {}
numeric! { BsonNumber }

/// An Atlas Search operator parameter that can be compared using [`range`].
pub trait RangeValue: private::Parameter {}
numeric! { RangeValue }
impl RangeValue for DateTime {}
impl RangeValue for &str {}
impl RangeValue for &String {}
impl RangeValue for String {}
impl RangeValue for crate::bson::oid::ObjectId {}
