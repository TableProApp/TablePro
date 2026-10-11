use crate::bson::Document;

use crate::bson::doc;
use serde::{Deserialize, Serialize};
use typed_builder::TypedBuilder;

/// Specifies the options for a search index.
#[serde_with::skip_serializing_none]
#[derive(Debug, Clone, Default, TypedBuilder, Serialize, Deserialize)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct SearchIndexModel {
    /// The definition for this index.
    pub definition: Document,

    /// The name for this index, if present.
    pub name: Option<String>,

    /// The type for this index, if present.
    #[serde(rename = "type")]
    pub index_type: Option<SearchIndexType>,
}

/// Specifies the type of search index.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SearchIndexType {
    /// A regular search index.
    Search,
    /// A vector search index.
    VectorSearch,
    /// An unknown type of search index.
    #[serde(untagged)]
    Other(String),
}

pub mod options {
    #[cfg(docsrs)]
    use crate::Collection;
    use macro_magic::export_tokens;
    use serde::Deserialize;
    use typed_builder::TypedBuilder;

    /// Options for [Collection::create_search_index].  Present to allow additional options to be
    /// added in the future as a non-breaking change.
    #[derive(Clone, Debug, Default, TypedBuilder, Deserialize)]
    #[builder(field_defaults(default, setter(into)))]
    #[non_exhaustive]
    #[export_tokens]
    pub struct CreateSearchIndexOptions {}

    /// Options for [Collection::update_search_index].  Present to allow additional options to be
    /// added in the future as a non-breaking change.
    #[derive(Clone, Debug, Default, TypedBuilder, Deserialize)]
    #[builder(field_defaults(default, setter(into)))]
    #[non_exhaustive]
    #[export_tokens]
    pub struct UpdateSearchIndexOptions {}

    /// Options for [Collection::list_search_indexes].  Present to allow additional options to be
    /// added in the future as a non-breaking change.
    #[derive(Clone, Debug, Default, TypedBuilder, Deserialize)]
    #[builder(field_defaults(default, setter(into)))]
    #[non_exhaustive]
    #[export_tokens]
    pub struct ListSearchIndexOptions {}

    /// Options for [Collection::drop_search_index].  Present to allow additional options to be
    /// added in the future as a non-breaking change.
    #[derive(Clone, Debug, Default, TypedBuilder, Deserialize)]
    #[builder(field_defaults(default, setter(into)))]
    #[non_exhaustive]
    #[export_tokens]
    pub struct DropSearchIndexOptions {}
}
