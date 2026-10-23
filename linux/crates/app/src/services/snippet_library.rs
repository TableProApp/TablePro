//! The SQL editor's snippets: the built-in statements for the engine and
//! the user's own files from the snippets folder.
//!
//! GtkSourceView's default `GtkSourceSnippetManager` reads its folders
//! once and keys snippets by the buffer's language alone, so the library
//! keeps a manager of its own on the folder and makes a new one after
//! the folder changes.

use std::cell::{OnceCell, RefCell};
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;

use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::sql_syntax::{SqlGrammar, builtin_snippets};

/// What a snippet file's `languages` names for every engine that speaks
/// SQL, and for a tab with no connection.
pub const ANY_SQL: &str = "sql";

/// A snippet the completion can offer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OfferedSnippet {
    pub trigger: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub origin: SnippetOrigin,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnippetOrigin {
    /// Its text, in GtkSourceView's snippet syntax.
    BuiltIn(&'static str),
    /// A file in the folder, under the `languages` entry it was read for.
    Folder { language: String },
}

/// One snippet a file in the folder holds.
#[derive(Debug, Clone, PartialEq, Eq)]
struct FolderSnippet {
    language: String,
    trigger: String,
    name: Option<String>,
    description: Option<String>,
}

struct Loaded {
    manager: sourceview5::SnippetManager,
    snippets: Rc<[FolderSnippet]>,
}

/// One per application. GTK-thread only.
pub struct SnippetLibrary {
    folder: PathBuf,
    monitor: OnceCell<Option<gio::FileMonitor>>,
    loaded: RefCell<Option<Rc<Loaded>>>,
}

impl SnippetLibrary {
    /// Nothing is read or watched until a completion first asks.
    pub fn new(folder: PathBuf) -> Rc<Self> {
        Rc::new(Self {
            folder,
            monitor: OnceCell::new(),
            loaded: RefCell::new(None),
        })
    }

    /// The snippets a completion offers on a connection to `driver`
    /// (none for a tab with no connection) whose SQL is `grammar`, one per
    /// trigger: a file's snippet for the engine before its `sql` one, and
    /// either before the built-in with the same trigger.
    pub fn offered(self: &Rc<Self>, driver: Option<&str>, grammar: SqlGrammar) -> Vec<OfferedSnippet> {
        let folder = self.loaded().snippets.clone();
        let mut languages: Vec<&str> = driver.into_iter().collect();
        if grammar.is_sql() {
            languages.push(ANY_SQL);
        }
        let mut offered = Vec::new();
        let mut triggers: HashSet<String> = HashSet::new();
        for language in languages {
            for snippet in folder.iter().filter(|snippet| snippet.language == language) {
                if triggers.insert(snippet.trigger.clone()) {
                    offered.push(OfferedSnippet {
                        trigger: snippet.trigger.clone(),
                        name: snippet.name.clone(),
                        description: snippet.description.clone(),
                        origin: SnippetOrigin::Folder {
                            language: snippet.language.clone(),
                        },
                    });
                }
            }
        }
        for builtin in builtin_snippets(grammar) {
            if triggers.insert(builtin.trigger.to_owned()) {
                offered.push(OfferedSnippet {
                    trigger: builtin.trigger.to_owned(),
                    name: Some(builtin.name.to_owned()),
                    description: None,
                    origin: SnippetOrigin::BuiltIn(builtin.text),
                });
            }
        }
        offered
    }

    /// A new `GtkSourceSnippet` for `offered`, ready to push into a view.
    /// `None` when its file changed since it was offered and no longer
    /// holds it.
    pub fn snippet(self: &Rc<Self>, offered: &OfferedSnippet) -> Option<sourceview5::Snippet> {
        match &offered.origin {
            SnippetOrigin::BuiltIn(text) => match sourceview5::Snippet::new_parsed(text) {
                Ok(snippet) => {
                    snippet.set_trigger(&offered.trigger);
                    Some(snippet)
                }
                Err(error) => {
                    tracing::warn!(%error, trigger = offered.trigger, "a built-in snippet did not parse");
                    None
                }
            },
            SnippetOrigin::Folder { language } => self.loaded().manager.snippet(None, Some(language), &offered.trigger),
        }
    }

    fn loaded(self: &Rc<Self>) -> Rc<Loaded> {
        self.watch();
        if let Some(loaded) = self.loaded.borrow().as_ref() {
            return loaded.clone();
        }
        let loaded = Rc::new(self.load());
        self.loaded.replace(Some(loaded.clone()));
        loaded
    }

    /// A manager reads its files on the first query, so a new one is
    /// what reads the folder again.
    fn load(&self) -> Loaded {
        let search_path: Vec<String> = match self.folder.to_str() {
            Some(folder) => vec![folder.to_owned()],
            None => {
                tracing::warn!(folder = %self.folder.display(), "the snippets folder's path is not UTF-8");
                Vec::new()
            }
        };
        let manager = sourceview5::SnippetManager::builder().search_path(search_path).build();
        let snippets = read_snippets(&manager.list_all());
        Loaded {
            manager,
            snippets: snippets.into(),
        }
    }

    fn watch(self: &Rc<Self>) {
        self.monitor.get_or_init(|| {
            // GLib keeps watching a folder that does not exist yet, and
            // reports it once it is made.
            let monitor = gio::File::for_path(&self.folder)
                .monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE);
            match monitor {
                Ok(monitor) => {
                    let library = Rc::downgrade(self);
                    monitor.connect_changed(move |_, _, _, _| {
                        if let Some(library) = library.upgrade() {
                            library.loaded.replace(None);
                        }
                    });
                    Some(monitor)
                }
                Err(error) => {
                    tracing::warn!(%error, folder = %self.folder.display(), "cannot watch the snippets folder");
                    None
                }
            }
        });
    }
}

/// The first snippet for each language and trigger, which is the one
/// `gtk_source_snippet_manager_get_snippet` returns for them. Name and
/// description are optional in the format, so they are read as
/// properties, which allow a NULL.
fn read_snippets(all: &gio::ListModel) -> Vec<FolderSnippet> {
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut snippets = Vec::new();
    for snippet in (0..all.n_items()).filter_map(|at| all.item(at).and_downcast::<sourceview5::Snippet>()) {
        let trigger = snippet.property::<Option<String>>("trigger");
        let language = snippet.property::<Option<String>>("language-id");
        let (Some(trigger), Some(language)) = (trigger, language) else {
            continue;
        };
        if !seen.insert((language.clone(), trigger.clone())) {
            continue;
        }
        snippets.push(FolderSnippet {
            language,
            trigger,
            name: non_empty(snippet.property("name")),
            description: non_empty(snippet.property("description")),
        });
    }
    snippets
}

fn non_empty(text: Option<String>) -> Option<String> {
    text.filter(|text| !text.trim().is_empty())
}

impl std::fmt::Debug for SnippetLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SnippetLibrary")
            .field("folder", &self.folder)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use sourceview5::prelude::*;

    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(15);

    fn snippet_file(group: &str, snippets: &[(&str, &str, &str)]) -> String {
        let body: String = snippets
            .iter()
            .map(|(trigger, languages, text)| {
                format!(
                    "  <snippet _name=\"{trigger} name\" trigger=\"{trigger}\" _description=\"{trigger} description\">\n    <text languages=\"{languages}\"><![CDATA[{text}]]></text>\n  </snippet>\n"
                )
            })
            .collect();
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<snippets _group=\"{group}\">\n{body}</snippets>\n")
    }

    fn triggers(offered: &[OfferedSnippet]) -> Vec<&str> {
        offered.iter().map(|snippet| snippet.trigger.as_str()).collect()
    }

    fn find<'a>(offered: &'a [OfferedSnippet], trigger: &str) -> &'a OfferedSnippet {
        offered
            .iter()
            .find(|snippet| snippet.trigger == trigger)
            .unwrap_or_else(|| panic!("no {trigger} in {:?}", triggers(offered)))
    }

    #[gtk4::test]
    fn every_built_in_writes_its_defaults_and_selects_its_first_stop() {
        let library = SnippetLibrary::new(PathBuf::from("/nonexistent/tablepro-test/snippets"));
        for grammar in SqlGrammar::SQL {
            for offered in library.offered(None, grammar) {
                let SnippetOrigin::BuiltIn(text) = offered.origin else {
                    panic!("{} is not a built-in", offered.trigger);
                };
                let view = sourceview5::View::new();
                let buffer = view.buffer();
                let snippet = library.snippet(&offered).expect("the built-in parses");
                let stops: HashSet<i32> = (0..snippet.n_chunks())
                    .map(|nth| snippet.nth_chunk(nth).focus_position())
                    .filter(|position| *position > 0)
                    .collect();
                let mut first = None;
                let expected = tablepro_test_support::expand_snippet(text, |default| {
                    first.get_or_insert_with(|| default.to_owned());
                    None
                })
                .expect("the built-in expands");

                view.push_snippet(&snippet, Some(&mut buffer.start_iter()));

                let written = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
                assert_eq!(written, expected, "{grammar:?} {}", offered.trigger);
                assert_eq!(
                    stops.len(),
                    text.matches("${").count(),
                    "{grammar:?} {}",
                    offered.trigger
                );
                let selected = buffer
                    .selection_bounds()
                    .map(|(start, end)| buffer.text(&start, &end, false).to_string());
                assert_eq!(selected, first, "{grammar:?} {}", offered.trigger);
            }
        }
    }

    #[gtk4::test]
    fn an_empty_folder_offers_the_engines_built_ins() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let library = SnippetLibrary::new(root.path().join("snippets"));

        let offered = library.offered(Some("postgres"), SqlGrammar::PostgreSql);

        assert_eq!(triggers(&offered), ["sel", "ins", "upd", "del", "selj", "ctab", "cidx"]);
        assert_eq!(find(&offered, "ins").name.as_deref(), Some("INSERT INTO … VALUES"));
        assert!(library.offered(Some("redis"), SqlGrammar::Redis).is_empty());
    }

    #[gtk4::test]
    fn a_files_snippet_shows_on_its_engine_and_on_every_sql_engine_for_sql() {
        let root = tempfile::tempdir().expect("a temporary folder");
        std::fs::write(
            root.path().join("mine.snippets"),
            snippet_file(
                "Mine",
                &[
                    ("vac", "postgres", "VACUUM ${1:table_name};$0"),
                    ("cnt", "sql", "SELECT COUNT(*) FROM ${1:table_name};$0"),
                    ("scan", "redis", "SCAN ${1:0} MATCH ${2:*}$0"),
                ],
            ),
        )
        .expect("write the file");
        let library = SnippetLibrary::new(root.path().to_owned());

        let postgres = library.offered(Some("postgres"), SqlGrammar::PostgreSql);
        let mysql = library.offered(Some("mysql"), SqlGrammar::MySql);
        let redis = library.offered(Some("redis"), SqlGrammar::Redis);
        let unconnected = library.offered(None, SqlGrammar::PostgreSql);

        assert!(triggers(&postgres).contains(&"vac") && triggers(&postgres).contains(&"cnt"));
        assert!(!triggers(&mysql).contains(&"vac"), "a PostgreSQL snippet on MySQL");
        assert!(triggers(&mysql).contains(&"cnt"));
        assert_eq!(triggers(&redis), ["scan"], "SQL on a Redis connection");
        assert!(!triggers(&unconnected).contains(&"vac"));
        assert!(triggers(&unconnected).contains(&"cnt"));
        let vac = find(&postgres, "vac");
        assert_eq!(vac.name.as_deref(), Some("vac name"));
        assert_eq!(vac.description.as_deref(), Some("vac description"));
        assert_eq!(
            vac.origin,
            SnippetOrigin::Folder {
                language: "postgres".to_owned()
            }
        );
    }

    #[gtk4::test]
    fn the_engines_snippet_beats_the_sql_one_and_either_beats_the_built_in() {
        let root = tempfile::tempdir().expect("a temporary folder");
        std::fs::write(
            root.path().join("mine.snippets"),
            snippet_file(
                "Mine",
                &[
                    ("ins", "sql", "INSERT INTO ${1:t} DEFAULT VALUES;$0"),
                    ("sel", "sql", "SELECT 1;$0"),
                    ("sel", "postgres", "SELECT 2;$0"),
                ],
            ),
        )
        .expect("write the file");
        let library = SnippetLibrary::new(root.path().to_owned());

        let offered = library.offered(Some("postgres"), SqlGrammar::PostgreSql);

        assert_eq!(
            triggers(&offered).iter().filter(|trigger| **trigger == "sel").count(),
            1
        );
        let sel = find(&offered, "sel");
        assert_eq!(
            sel.origin,
            SnippetOrigin::Folder {
                language: "postgres".to_owned()
            }
        );
        let ins = find(&offered, "ins");
        assert!(matches!(ins.origin, SnippetOrigin::Folder { .. }), "the built-in won");
        let pushed = library.snippet(sel).expect("the file's snippet");
        assert_eq!(pushed.trigger().as_deref(), Some("sel"));
        assert_eq!(
            pushed.property::<Option<String>>("language-id").as_deref(),
            Some("postgres")
        );
    }

    #[gtk4::test]
    fn a_file_added_to_the_folder_is_offered_without_a_restart() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let library = SnippetLibrary::new(root.path().to_owned());
        assert!(!triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt"));

        std::fs::write(
            root.path().join("added.snippets"),
            snippet_file("Added", &[("cnt", "sql", "SELECT COUNT(*) FROM ${1:t};$0")]),
        )
        .expect("write the file");

        wait_until(WAIT, || {
            triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt")
        })
        .expect("the new file's snippet");
    }

    #[gtk4::test]
    fn a_folder_made_after_the_first_read_is_watched() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let folder = root.path().join("snippets");
        let library = SnippetLibrary::new(folder.clone());
        assert!(!triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt"));

        std::fs::create_dir(&folder).expect("make the folder");
        std::fs::write(
            folder.join("added.snippets"),
            snippet_file("Added", &[("cnt", "sql", "SELECT COUNT(*) FROM ${1:t};$0")]),
        )
        .expect("write the file");

        wait_until(WAIT, || {
            triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt")
        })
        .expect("the snippet from a folder made later");
    }

    #[gtk4::test]
    fn a_removed_file_is_no_longer_offered() {
        let root = tempfile::tempdir().expect("a temporary folder");
        let file = root.path().join("mine.snippets");
        std::fs::write(
            &file,
            snippet_file("Mine", &[("cnt", "sql", "SELECT COUNT(*) FROM ${1:t};$0")]),
        )
        .expect("write the file");
        let library = SnippetLibrary::new(root.path().to_owned());
        assert!(triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt"));

        std::fs::remove_file(&file).expect("remove the file");

        wait_until(WAIT, || {
            !triggers(&library.offered(None, SqlGrammar::Sqlite)).contains(&"cnt")
        })
        .expect("the removed file's snippet gone");
    }

    #[gtk4::test]
    fn a_file_that_does_not_parse_leaves_the_others() {
        let root = tempfile::tempdir().expect("a temporary folder");
        // Broken before its first element: GtkSourceView logs a critical
        // for a file that breaks inside one, which a test that makes
        // criticals fatal would take for its own.
        std::fs::write(root.path().join("broken.snippets"), "not a snippets file\n").expect("write");
        std::fs::write(
            root.path().join("good.snippets"),
            snippet_file("Good", &[("cnt", "sql", "SELECT COUNT(*) FROM ${1:t};$0")]),
        )
        .expect("write the file");
        let library = SnippetLibrary::new(root.path().to_owned());

        let offered = library.offered(None, SqlGrammar::Sqlite);

        assert!(triggers(&offered).contains(&"cnt"));
        assert!(
            triggers(&offered).contains(&"ins"),
            "the built-ins went with the broken file"
        );
    }

    #[gtk4::test]
    fn a_snippet_without_name_or_description_is_offered_by_its_trigger() {
        let root = tempfile::tempdir().expect("a temporary folder");
        std::fs::write(
            root.path().join("bare.snippets"),
            "<snippets>\n  <snippet trigger=\"cnt\">\n    <text languages=\"sql\">SELECT COUNT(*) FROM ${1:t};$0</text>\n  </snippet>\n</snippets>\n",
        )
        .expect("write the file");
        let library = SnippetLibrary::new(root.path().to_owned());

        let offered = library.offered(None, SqlGrammar::Sqlite);
        let cnt = find(&offered, "cnt");

        assert_eq!((cnt.name.as_deref(), cnt.description.as_deref()), (None, None));
        assert!(library.snippet(cnt).is_some());
    }
}
