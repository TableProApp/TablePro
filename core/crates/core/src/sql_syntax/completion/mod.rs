// What the text before a caret asks for, how closely a name matches the word typed, and the order a list shows them
// in. An app reads the catalog (tablepro_session::completion), builds its own rows and inserts the choice.

mod catalog;
mod fuzzy;
mod ranking;
mod scope;
mod word;

pub use catalog::{CatalogAnswer, CatalogHome};
pub use fuzzy::{casefold, fuzzy_match, matched_runs, matches_word};
pub use ranking::{Ranked, Ranking};
pub use scope::{CompletionScope, analyze, tables_named};
pub use word::{is_word_char, word_start};
