//! Defines the [optional arguments](https://redis.io/docs/latest/commands/ft.create/#optional-arguments)
//! of the FT.CREATE command.
//!
//! # Example
//!
//! ```rust
//! use redis::search::{CreateOptions, IndexDataType, SearchLanguage};
//!
//! let options = CreateOptions::new()
//!     .on(IndexDataType::Hash)
//!     .prefix("blog:post:")
//!     .language(SearchLanguage::English);
//! ```
use crate::{RedisWrite, ToRedisArgs};

/// Data type for indexing
#[derive(Clone, Copy, Debug)]
#[non_exhaustive]
pub enum IndexDataType {
    /// Index hash data structures
    Hash,
    /// Index JSON data structures
    Json,
}

impl ToRedisArgs for IndexDataType {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(match self {
            Self::Hash => b"HASH",
            Self::Json => b"JSON",
        });
    }
}

/// Generates an enum with the supported languages for search
macro_rules! search_languages {
    ($($name:ident),* $(,)?) => {
        /// Supported languages for search
        #[derive(Debug, Clone, Copy)]
        #[non_exhaustive]
        #[allow(missing_docs)]
        pub enum SearchLanguage {
            $($name),*
        }

        impl std::fmt::Display for SearchLanguage {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                match self {
                    $(SearchLanguage::$name => write!(f, "{}", stringify!($name).to_uppercase()),)*
                }
            }
        }
    };
}

search_languages!(
    Arabic, Armenian, Basque, Catalan, Danish, Dutch, English, Finnish, French, German, Greek,
    Hindi, Hungarian, Indonesian, Irish, Italian, Lithuanian, Malay, Nepali, Norwegian, Portuguese,
    Romanian, Russian, Serbian, Spanish, Swedish, Tagalog, Tamil, Turkish, Yiddish, Chinese,
);

impl ToRedisArgs for SearchLanguage {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        out.write_arg(self.to_string().as_bytes());
    }
}

/// [Optional arguments](https://redis.io/docs/latest/commands/ft.create/#optional-arguments) for the FT.CREATE command
#[must_use = "Options have no effect unless passed to a command"]
#[derive(Default, Clone)]
#[non_exhaustive]
pub struct CreateOptions {
    on: Option<IndexDataType>,
    prefixes: Vec<String>,
    filter: Option<String>,
    language: Option<SearchLanguage>,
    language_field: Option<String>,
    score: Option<f64>,
    score_field: Option<String>,
    max_text_fields: bool,
    no_offsets: bool,
    temporary: Option<u64>,
    no_highlight: bool,
    no_fields: bool,
    no_freqs: bool,
    stopwords: Vec<String>,
    skip_initial_scan: bool,
}

impl CreateOptions {
    /// Create a new CreateOptions
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the index data type. Currently HASH (default) and JSON are supported.
    pub fn on(mut self, index_type: IndexDataType) -> Self {
        self.on = Some(index_type);
        self
    }

    /// Tell the index which keys it should index. Several prefixes can be specified.
    /// Because the argument is optional, the default is * (all keys).
    pub fn prefix<S: Into<String>>(mut self, prefix: S) -> Self {
        self.prefixes.push(prefix.into());
        self
    }

    /// A filter expression with the full Redis Search aggregation expression language.
    /// It is possible to use @__key to access the key that was just added/changed.
    pub fn filter<S: Into<String>>(mut self, filter: S) -> Self {
        self.filter = Some(filter.into());
        self
    }

    /// Indicate the default language for documents in the index.
    /// The default is English.
    pub fn language(mut self, language: SearchLanguage) -> Self {
        self.language = Some(language);
        self
    }

    /// Specify a document attribute that is set as the document language.
    pub fn language_field<S: Into<String>>(mut self, language_field: S) -> Self {
        self.language_field = Some(language_field.into());
        self
    }

    /// Specify a default score for documents in the index.
    /// The default is 1.0.
    pub fn score(mut self, score: f64) -> Self {
        self.score = Some(score);
        self
    }

    /// Specify a document attribute that is set as the document's rank.
    /// Ranking must be between 0.0 and 1.0. If not set, the default score is 1.
    pub fn score_field<S: Into<String>>(mut self, score_field: S) -> Self {
        self.score_field = Some(score_field.into());
        self
    }

    /// Force Redis Search to encode indices as if there were more than 32 text attributes.
    /// This allows additional attributes (beyond 32) to be added using FT.ALTER.
    /// For efficiency, Redis Search encodes indices differently if they are created with less than 32 text attributes.
    pub fn max_text_fields(mut self) -> Self {
        self.max_text_fields = true;
        self
    }

    /// Do not store term offsets for documents. It saves memory, but does not allow exact searches or highlighting.
    /// It implies NOHL.
    pub fn no_offsets(mut self) -> Self {
        self.no_offsets = true;
        self
    }

    /// Create a lightweight temporary index that expires after a specified period of inactivity (in seconds).
    /// The internal idle timer is reset whenever the index is searched or added to.
    pub fn temporary(mut self, secs: u64) -> Self {
        self.temporary = Some(secs);
        self
    }

    /// Conserve storage space and memory by disabling highlighting support.
    /// If set, the corresponding byte offsets for term positions are not stored.
    /// NOHL is also implied by NOOFFSETS.
    pub fn no_highlight(mut self) -> Self {
        self.no_highlight = true;
        self
    }

    /// Do not store attribute bits for each term. It saves memory, but it does not allow filtering by specific attributes.
    pub fn no_fields(mut self) -> Self {
        self.no_fields = true;
        self
    }

    /// Avoid saving the term frequencies in the index. It saves memory, but does not allow sorting based on the frequencies of a given term within the document.
    pub fn no_freqs(mut self) -> Self {
        self.no_freqs = true;
        self
    }

    /// Set the index with a custom stopword list, to be ignored during indexing and search time.
    pub fn stopword<S: Into<String>>(mut self, stopword: S) -> Self {
        self.stopwords.push(stopword.into());
        self
    }

    /// Do not scan and index.
    pub fn skip_initial_scan(mut self) -> Self {
        self.skip_initial_scan = true;
        self
    }
}

impl ToRedisArgs for CreateOptions {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + RedisWrite,
    {
        if let Some(ref on) = self.on {
            out.write_arg(b"ON");
            on.write_redis_args(out);
        }

        if !self.prefixes.is_empty() {
            out.write_arg(b"PREFIX");
            self.prefixes.len().write_redis_args(out);
            for prefix in &self.prefixes {
                prefix.write_redis_args(out);
            }
        }

        if let Some(ref filter) = self.filter {
            out.write_arg(b"FILTER");
            format!("'{filter}'").write_redis_args(out);
        }

        if let Some(ref language) = self.language {
            out.write_arg(b"LANGUAGE");
            language.write_redis_args(out);
        }

        if let Some(ref language_field) = self.language_field {
            out.write_arg(b"LANGUAGE_FIELD");
            language_field.write_redis_args(out);
        }

        if let Some(score) = self.score {
            out.write_arg(b"SCORE");
            score.write_redis_args(out);
        }

        if let Some(ref score_field) = self.score_field {
            out.write_arg(b"SCORE_FIELD");
            score_field.write_redis_args(out);
        }

        if self.max_text_fields {
            out.write_arg(b"MAXTEXTFIELDS");
        }

        if self.no_offsets {
            out.write_arg(b"NOOFFSETS");
        }

        if let Some(temporary) = self.temporary {
            out.write_arg(b"TEMPORARY");
            temporary.write_redis_args(out);
        }

        if self.no_highlight {
            out.write_arg(b"NOHL");
        }

        if self.no_fields {
            out.write_arg(b"NOFIELDS");
        }

        if self.no_freqs {
            out.write_arg(b"NOFREQS");
        }

        if !self.stopwords.is_empty() {
            out.write_arg(b"STOPWORDS");
            self.stopwords.len().write_redis_args(out);
            for stopword in &self.stopwords {
                stopword.write_redis_args(out);
            }
        }

        if self.skip_initial_scan {
            out.write_arg(b"SKIPINITIALSCAN");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str;

    macro_rules! assert_args {
        ($value:expr, $($args:expr),+) => {
            let args = $value.to_redis_args();
            let strings: Vec<_> = args.iter()
                                      .map(|a| str::from_utf8(a.as_ref()).unwrap())
                                      .collect();
            assert_eq!(strings, vec![$($args),+]);
        }
    }

    #[test]
    fn test_without_options_no_arguments_are_written() {
        assert_eq!(ToRedisArgs::to_redis_args(&CreateOptions::new()).len(), 0);
    }

    #[test]
    fn test_option_on_hash() {
        assert_args!(CreateOptions::new().on(IndexDataType::Hash), "ON", "HASH");
    }

    #[test]
    fn test_option_on_json() {
        assert_args!(CreateOptions::new().on(IndexDataType::Json), "ON", "JSON");
    }

    #[test]
    fn test_option_prefix_single() {
        assert_args!(
            CreateOptions::new().prefix("prefix"),
            "PREFIX",
            "1",
            "prefix"
        );
    }

    #[test]
    fn test_option_prefix_multiple() {
        assert_args!(
            CreateOptions::new().prefix("pref1").prefix("pref2"),
            "PREFIX",
            "2",
            "pref1",
            "pref2"
        );
    }

    #[test]
    fn test_option_filter() {
        assert_args!(
            CreateOptions::new().filter("@field != \"\""),
            "FILTER",
            "'@field != \"\"'"
        );
    }

    #[test]
    fn test_option_language() {
        assert_args!(
            CreateOptions::new().language(SearchLanguage::Arabic),
            "LANGUAGE",
            "ARABIC"
        );
    }

    #[test]
    fn test_option_language_field() {
        assert_args!(
            CreateOptions::new().language_field("lang"),
            "LANGUAGE_FIELD",
            "lang"
        );
    }

    #[test]
    fn test_option_score() {
        assert_args!(CreateOptions::new().score(0.5), "SCORE", "0.5");
    }

    #[test]
    fn test_option_score_field() {
        assert_args!(
            CreateOptions::new().score_field("rank"),
            "SCORE_FIELD",
            "rank"
        );
    }

    #[test]
    fn test_option_max_text_fields() {
        assert_args!(CreateOptions::new().max_text_fields(), "MAXTEXTFIELDS");
    }

    #[test]
    fn test_option_no_offsets() {
        assert_args!(CreateOptions::new().no_offsets(), "NOOFFSETS");
    }

    #[test]
    fn test_option_temporary() {
        assert_args!(CreateOptions::new().temporary(3600), "TEMPORARY", "3600");
    }

    #[test]
    fn test_option_no_highlight() {
        assert_args!(CreateOptions::new().no_highlight(), "NOHL");
    }

    #[test]
    fn test_option_no_fields() {
        assert_args!(CreateOptions::new().no_fields(), "NOFIELDS");
    }

    #[test]
    fn test_option_no_freqs() {
        assert_args!(CreateOptions::new().no_freqs(), "NOFREQS");
    }

    #[test]
    fn test_option_stopwords_single() {
        assert_args!(
            CreateOptions::new().stopword("the"),
            "STOPWORDS",
            "1",
            "the"
        );
    }

    #[test]
    fn test_option_stopwords_multiple() {
        assert_args!(
            CreateOptions::new().stopword("the").stopword("and"),
            "STOPWORDS",
            "2",
            "the",
            "and"
        );
    }

    #[test]
    fn test_option_skip_initial_scan() {
        assert_args!(CreateOptions::new().skip_initial_scan(), "SKIPINITIALSCAN");
    }

    /// Pins the order in which the modifiers are written, which FT.CREATE relies on.
    #[test]
    fn test_all_options_are_written_in_order() {
        assert_args!(
            CreateOptions::new()
                .on(IndexDataType::Json)
                .prefix("doc:")
                .filter("@field != \"\"")
                .language(SearchLanguage::English)
                .language_field("lang")
                .score(0.5)
                .score_field("rank")
                .max_text_fields()
                .no_offsets()
                .temporary(3600)
                .no_highlight()
                .no_fields()
                .no_freqs()
                .stopword("the")
                .skip_initial_scan(),
            "ON",
            "JSON",
            "PREFIX",
            "1",
            "doc:",
            "FILTER",
            "'@field != \"\"'",
            "LANGUAGE",
            "ENGLISH",
            "LANGUAGE_FIELD",
            "lang",
            "SCORE",
            "0.5",
            "SCORE_FIELD",
            "rank",
            "MAXTEXTFIELDS",
            "NOOFFSETS",
            "TEMPORARY",
            "3600",
            "NOHL",
            "NOFIELDS",
            "NOFREQS",
            "STOPWORDS",
            "1",
            "the",
            "SKIPINITIALSCAN"
        );
    }
}
