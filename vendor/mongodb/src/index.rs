pub mod options;

use crate::bson::Document;

use self::options::*;
use serde::{Deserialize, Serialize};

use typed_builder::TypedBuilder;

/// Specifies the fields and options for an index. For more information, see the [documentation](https://www.mongodb.com/docs/manual/indexes/).
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct IndexModel {
    /// Specifies the index’s fields. For each field, specify a key-value pair in which the key is
    /// the name of the field to index and the value is index type.
    #[serde(rename = "key")]
    pub keys: Document,

    /// The options for the index.
    #[serde(flatten)]
    pub options: Option<IndexOptions>,
}

impl IndexModel {
    /// If the client did not specify a name, generate and set it. Otherwise, do nothing.
    pub(crate) fn update_name(&mut self) {
        if self
            .options
            .as_ref()
            .and_then(|o| o.name.as_ref())
            .is_none()
        {
            fn format_kv(kv: (&String, &crate::bson::Bson)) -> String {
                if let crate::bson::Bson::String(s) = kv.1 {
                    format!("{}_{}", kv.0, s)
                } else {
                    format!("{}_{}", kv.0, kv.1)
                }
            }
            let key_names: Vec<String> = self.keys.iter().map(format_kv).collect();
            self.options.get_or_insert(IndexOptions::default()).name = Some(key_names.join("_"));
        }
    }

    pub(crate) fn get_name(&self) -> Option<String> {
        self.options.as_ref().and_then(|o| o.name.as_ref()).cloned()
    }

    #[cfg(test)]
    pub(crate) fn is_unique(&self) -> bool {
        self.options
            .as_ref()
            .and_then(|o| o.unique)
            .unwrap_or(false)
    }
}
