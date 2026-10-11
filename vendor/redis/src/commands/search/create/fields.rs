//! Defines the schema field types used with the FT.CREATE command.
use crate::{RedisWrite, ToRedisArgs};

/// Field type for schema definition.
/// More information at: <https://redis.io/docs/latest/commands/ft.create/#required-arguments>
#[derive(Clone, Copy, Debug)]
#[non_exhaustive]
pub enum FieldType {
    /// Allows full-text search queries against the value in this attribute.
    Text,
    /// Allows exact-match queries, such as categories or primary keys, against the value in this attribute.
    Tag,
    /// Allows numeric range queries against the value in this attribute.
    Numeric,
    /// Allows radius range queries against the value (point) in this attribute.
    Geo,
    /// Allows vector queries against the value in this attribute. This requires query dialect 2 or above (introduced in RediSearch v2.4).
    Vector,
    /// Allows polygon queries against the value in this attribute.
    GeoShape,
}

impl ToRedisArgs for FieldType {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(match self {
            Self::Text => b"TEXT",
            Self::Tag => b"TAG",
            Self::Numeric => b"NUMERIC",
            Self::Geo => b"GEO",
            Self::Vector => b"VECTOR",
            Self::GeoShape => b"GEOSHAPE",
        });
    }
}

impl FieldType {
    /// Returns whether the field type is sortable.
    pub fn is_sortable(&self) -> bool {
        matches!(self, Self::Text | Self::Tag | Self::Numeric | Self::Geo)
    }
}

/// Enumeration for sortable fields
/// <https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/sorting/>
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum Sortable {
    /// Apply sortable
    Yes,
    /// Apply sortable with un-normalized form
    Unf,
}

impl ToRedisArgs for Sortable {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        match self {
            Self::Yes => out.write_arg(b"SORTABLE"),
            Self::Unf => {
                out.write_arg(b"SORTABLE");
                out.write_arg(b"UNF");
            }
        }
    }
}

/// Declaring a text attribute as PHONETIC will perform phonetic matching on it in searches by default.
/// The obligatory argument specifies the phonetic algorithm and language used.
/// <https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/phonetic_matching/>
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum Phonetic {
    /// Double metaphone for English
    DmEnglish,
    /// Double metaphone for French
    DmFrench,
    /// Double metaphone for Portuguese
    DmPortuguese,
    /// Double metaphone for Spanish
    DmSpanish,
}

impl ToRedisArgs for Phonetic {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(match self {
            Self::DmEnglish => b"dm:en",
            Self::DmFrench => b"dm:fr",
            Self::DmPortuguese => b"dm:pt",
            Self::DmSpanish => b"dm:es",
        });
    }
}

#[derive(Debug, Clone)]
#[non_exhaustive]
pub(crate) struct BaseSchemaField {
    pub field_type: FieldType,
    pub alias: Option<String>,
    pub index_missing: bool,
}

impl BaseSchemaField {
    pub(crate) fn new(field_type: FieldType) -> Self {
        Self {
            field_type,
            alias: None,
            index_missing: false,
        }
    }

    pub fn alias(mut self, alias: impl Into<String>) -> Self {
        self.alias = Some(alias.into());
        self
    }

    pub fn index_missing(mut self, index_missing: bool) -> Self {
        self.index_missing = index_missing;
        self
    }
}

impl ToRedisArgs for BaseSchemaField {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if let Some(alias) = &self.alias {
            out.write_arg(b"AS");
            alias.write_redis_args(out);
        }

        self.field_type.write_redis_args(out);

        if self.index_missing {
            out.write_arg(b"INDEXMISSING");
        }
    }
}

#[derive(Debug, Clone)]
#[non_exhaustive]
pub(crate) struct SchemaCommonField {
    pub base: BaseSchemaField,
    pub sortable: Option<Sortable>,
    pub no_index: bool,
}

impl SchemaCommonField {
    pub(crate) fn new(field_type: FieldType) -> Self {
        Self {
            base: BaseSchemaField::new(field_type),
            sortable: None,
            no_index: false,
        }
    }

    pub fn sortable(mut self, sortable: Sortable) -> Self {
        if self.base.field_type.is_sortable() {
            self.sortable = Some(sortable);
        } else {
            unreachable!("Field type {:?} is not sortable", self.base.field_type);
        }
        self
    }

    pub fn no_index(mut self, no_index: bool) -> Self {
        self.no_index = no_index;
        self
    }

    pub fn alias(mut self, alias: impl Into<String>) -> Self {
        self.base = self.base.alias(alias);
        self
    }

    pub fn index_missing(mut self, index_missing: bool) -> Self {
        self.base = self.base.index_missing(index_missing);
        self
    }
}

impl ToRedisArgs for SchemaCommonField {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if let Some(sortable) = &self.sortable {
            sortable.write_redis_args(out);
        }

        if self.no_index {
            out.write_arg(b"NOINDEX");
        }
    }
}

/// Represents a text field in the schema.
#[must_use = "Text field has no effect unless inserted into a schema"]
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct SchemaTextField {
    pub(crate) common: SchemaCommonField,
    no_stem: bool,
    weight: Option<f64>,
    phonetic: Option<Phonetic>,
    with_suffix_trie: bool,
    index_empty: bool,
}

impl SchemaTextField {
    /// Create a new TEXT field.
    pub fn new() -> Self {
        Self {
            common: SchemaCommonField::new(FieldType::Text),
            no_stem: false,
            weight: None,
            phonetic: None,
            with_suffix_trie: false,
            index_empty: false,
        }
    }

    /// Disables stemming when indexing the text field's values. This may be ideal for things like proper names.
    /// <https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/stemming/>
    pub fn no_stem(mut self, no_stem: bool) -> Self {
        self.no_stem = no_stem;
        self
    }

    /// Declares the importance of this attribute when calculating result accuracy.
    /// This is a multiplication factor and defaults to 1 if not specified.
    pub fn weight(mut self, weight: f64) -> Self {
        self.weight = Some(weight);
        self
    }

    /// Declaring a text attribute as PHONETIC will perform phonetic matching on it in searches by default.
    /// <https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/phonetic_matching/>
    pub fn phonetic(mut self, phonetic: Phonetic) -> Self {
        self.phonetic = Some(phonetic);
        self
    }

    /// Keeps a suffix trie with all terms which match the suffix. It is used to optimize contains (foo) and suffix (*foo) queries.
    /// Otherwise, a brute-force search on the trie is performed. If suffix trie exists for some fields, these queries will be disabled for other fields.
    pub fn with_suffix_trie(mut self, with_suffix_trie: bool) -> Self {
        self.with_suffix_trie = with_suffix_trie;
        self
    }

    /// Index empty strings. This allows searching for empty values - documents that do not contain a specific field.
    /// By default, empty strings are not indexed.
    pub fn index_empty(mut self, index_empty: bool) -> Self {
        self.index_empty = index_empty;
        self
    }

    /// Mark the field as sortable.
    pub fn sortable(mut self, sortable: Sortable) -> Self {
        self.common = self.common.sortable(sortable);
        self
    }

    /// Mark the field as no index. This means that the field will not be indexed.
    pub fn no_index(mut self, no_index: bool) -> Self {
        self.common = self.common.no_index(no_index);
        self
    }

    /// Set the alias for the field.
    pub fn alias(mut self, alias: impl Into<String>) -> Self {
        self.common = self.common.alias(alias);
        self
    }

    /// Set index missing. This allows searching for missing values - documents that do not contain a specific field.
    pub fn index_missing(mut self, index_missing: bool) -> Self {
        self.common = self.common.index_missing(index_missing);
        self
    }
}

impl ToRedisArgs for SchemaTextField {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        self.common.base.write_redis_args(out);

        if self.no_stem {
            out.write_arg(b"NOSTEM");
        }
        if let Some(weight) = self.weight {
            out.write_arg(b"WEIGHT");
            weight.write_redis_args(out);
        }
        if let Some(phonetic) = &self.phonetic {
            out.write_arg(b"PHONETIC");
            phonetic.write_redis_args(out);
        }
        if self.with_suffix_trie {
            out.write_arg(b"WITHSUFFIXTRIE");
        }
        if self.index_empty {
            out.write_arg(b"INDEXEMPTY");
        }

        self.common.write_redis_args(out);
    }
}

impl Default for SchemaTextField {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema;
    use crate::search::FtCreateCommand;

    static INDEX_NAME: &str = "index";
    static TEXT_FIELD_NAME: &str = "title";
    static CUSTOM_ALIAS: &str = "custom_alias";

    // ============================================================================
    // TEXT Field Tests
    // ============================================================================
    #[test]
    fn test_text_field() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new(),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(ft_create.into_args(), "FT.CREATE index SCHEMA title TEXT");
    }

    #[test]
    fn test_text_field_with_nostem() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().no_stem(true),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT NOSTEM"
        );
    }

    #[test]
    fn test_text_field_with_weight() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().weight(1.0),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT WEIGHT 1.0"
        );
    }

    #[test]
    fn test_text_field_with_phonetic() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().phonetic(Phonetic::DmEnglish),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT PHONETIC dm:en"
        );
    }

    #[test]
    fn test_text_field_with_withsuffixtrie() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().with_suffix_trie(true),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT WITHSUFFIXTRIE"
        );
    }

    #[test]
    fn test_text_field_with_indexempty() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().index_empty(true),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT INDEXEMPTY"
        );
    }

    #[test]
    fn test_text_field_with_alias() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().alias(CUSTOM_ALIAS),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title AS custom_alias TEXT"
        );
    }

    #[test]
    fn test_text_field_with_indexmissing() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().index_missing(true),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT INDEXMISSING"
        );
    }

    #[test]
    fn test_text_field_with_sortable() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().sortable(Sortable::Yes),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT SORTABLE"
        );
    }

    #[test]
    fn test_text_field_with_sortable_unf() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().sortable(Sortable::Unf),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT SORTABLE UNF"
        );
    }

    #[test]
    fn test_text_field_with_noindex() {
        let schema = schema! {
            TEXT_FIELD_NAME => SchemaTextField::new().no_index(true),
        };
        let ft_create = FtCreateCommand::new(INDEX_NAME, schema);
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title TEXT NOINDEX"
        );
    }

    #[test]
    fn test_text_field_with_all_options() {
        let field = SchemaTextField::new()
            .no_stem(true)
            .weight(1.0)
            .phonetic(Phonetic::DmEnglish)
            .with_suffix_trie(true)
            .index_empty(true)
            .alias(CUSTOM_ALIAS)
            .index_missing(true)
            .sortable(Sortable::Unf);
        let ft_create = FtCreateCommand::new(
            INDEX_NAME,
            schema! {
                TEXT_FIELD_NAME => field.clone(),
            },
        );
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title AS custom_alias TEXT INDEXMISSING NOSTEM WEIGHT 1.0 PHONETIC dm:en WITHSUFFIXTRIE INDEXEMPTY SORTABLE UNF"
        );
        // Index missing and no index are mutually exclusive
        let ft_create = FtCreateCommand::new(
            INDEX_NAME,
            schema! {
                TEXT_FIELD_NAME => field.index_missing(false).no_index(true),
            },
        );
        assert_eq!(
            ft_create.into_args(),
            "FT.CREATE index SCHEMA title AS custom_alias TEXT NOSTEM WEIGHT 1.0 PHONETIC dm:en WITHSUFFIXTRIE INDEXEMPTY SORTABLE UNF NOINDEX"
        );
    }
}
