use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::CompletionColumn;
use sourceview5::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::ObjectInfo;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, text_offsets};
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;

use super::catalog_read::{self, CatalogAnswer};
use super::completion_scope::{self, CompletionScope};
use super::fuzzy;
use super::proposal_kind::ProposalKind;
use super::proposal_list::{Candidate, ProposalList, Ranking};
use super::sql_completion_provider_imp as imp;
use super::sql_proposal::SqlProposal;
use crate::services::active_session::ActiveSession;
use crate::services::snippet_library::SnippetLibrary;

glib::wrapper! {
    /// Completes keywords, snippets, and the tables, views and columns of
    /// the session's catalog, for what the statement at the cursor asks.
    pub struct SqlCompletionProvider(ObjectSubclass<imp::SqlCompletionProvider>)
        @implements sourceview5::CompletionProvider;
}

/// How far before and after the cursor a completion reads the buffer, in
/// characters. A file of megabytes would otherwise be copied and lexed
/// on the GTK thread every time a word starts.
pub const CONTEXT_BEFORE: i32 = 128 * 1024;
pub const CONTEXT_AFTER: i32 = 32 * 1024;

pub struct ProviderDeps {
    session: ActiveSession,
    tasks: Tasks,
    pub(super) snippets: Rc<SnippetLibrary>,
}

impl SqlCompletionProvider {
    /// Resolve unqualified names in `database`, the tab's own when the
    /// editor bar moved it off the connection's.
    pub fn set_home(&self, database: Option<String>) {
        self.imp().home.replace(database);
    }

    pub fn new(session: ActiveSession, tasks: Tasks, snippets: Rc<SnippetLibrary>) -> Self {
        let provider: Self = glib::Object::new();
        let _ = provider.imp().deps.set(ProviderDeps {
            session,
            tasks,
            snippets,
        });
        provider
    }

    /// The proposals for `word`, which starts at character `word_start`
    /// of `buffer`. The catalog read, the candidates it gives and their
    /// ranking run on the runtime, so a schema of 50,000 tables never
    /// reaches the GTK thread as 50,000 objects.
    pub async fn proposals(&self, buffer: &gtk4::TextBuffer, word_start: i32, word: &str) -> gio::ListModel {
        let needle = fuzzy::casefold(word);
        let tasks = self.imp().deps.get().map(|deps| deps.tasks.clone());
        let Some(request) = self.request(buffer, word_start) else {
            return ProposalList::new(Ranking::new(Arc::from([]), &needle), tasks).upcast();
        };
        let ranking = match (request.session.clone(), tasks.clone()) {
            (Some(session), Some(tasks)) if request.grammar.is_sql() => {
                let fallback = request.clone();
                let home = self.imp().home.borrow().clone();
                let ranked_for = needle.clone();
                let blocking = tasks.clone();
                tasks
                    .spawn_task(async move {
                        let answer = catalog_read::read(session, request.scope.clone(), home).await;
                        blocking
                            .spawn_blocking_task(move || Ranking::new(request.candidates(&answer).into(), &ranked_for))
                            .await
                    })
                    .await
                    .and_then(|ranking| ranking)
                    .unwrap_or_else(|failure| {
                        tracing::warn!(%failure, "reading the catalog for completion failed");
                        Ranking::new(fallback.candidates(&CatalogAnswer::default()).into(), &needle)
                    })
            }
            _ => Ranking::new(request.candidates(&CatalogAnswer::default()).into(), &needle),
        };
        ProposalList::new(ranking, tasks).upcast()
    }

    /// Narrow the list to the word now typed.
    pub fn refilter(&self, word: &str, model: &gio::ListModel) {
        if let Some(list) = model.downcast_ref::<ProposalList>() {
            list.set_needle(&fuzzy::casefold(word));
        }
    }

    pub(super) fn empty(&self) -> gio::ListModel {
        let tasks = self.imp().deps.get().map(|deps| deps.tasks.clone());
        ProposalList::new(Ranking::new(Arc::from([]), ""), tasks).upcast()
    }

    fn request(&self, buffer: &gtk4::TextBuffer, word_start: i32) -> Option<Request> {
        let session = self.imp().deps.get().and_then(|deps| deps.session.get());
        let dialect = session.as_ref().and_then(|session| session.current_dialect());
        // With no connection the keywords still complete, and
        // PostgreSQL's reading of the text is the strictest.
        let grammar = dialect
            .as_ref()
            .map_or(SqlGrammar::PostgreSql, |dialect| dialect.grammar());
        let (start, end) = context_bounds(buffer, word_start);
        let text = buffer.text(&start, &end, false);
        let cursor = usize::try_from(word_start - start.offset()).unwrap_or_default();
        let cursor = text_offsets::char_to_byte(&text, cursor);
        let scope = completion_scope::analyze(&text, cursor, grammar, LexicalSettings::default_for(grammar))?;
        // Where a keyword can go, so can a statement. A command engine
        // has no catalog or keywords to complete, only its snippets.
        let offers_snippets = !grammar.is_sql() || matches!(scope, CompletionScope::General { .. });
        let snippets = match self.imp().deps.get() {
            Some(deps) if offers_snippets => {
                let driver = session.as_ref().map(|session| session.metadata().driver_id.as_str());
                deps.snippets
                    .offered(driver, grammar)
                    .into_iter()
                    .map(Candidate::snippet)
                    .collect()
            }
            _ => Vec::new(),
        };
        Some(Request {
            scope,
            grammar,
            session,
            dialect,
            snippets,
        })
    }
}

/// One completion's question, read on the GTK thread.
#[derive(Clone)]
struct Request {
    scope: CompletionScope,
    grammar: SqlGrammar,
    session: Option<Arc<Session>>,
    dialect: Option<Arc<dyn SqlDialect>>,
    /// Read on the GTK thread, where the snippet library lives.
    snippets: Vec<Candidate>,
}

impl Request {
    fn candidates(&self, answer: &CatalogAnswer) -> Vec<Candidate> {
        let mut proposals = Vec::new();
        let mut columns: HashSet<&str> = HashSet::new();
        for (table, list) in &answer.columns {
            for column in list.iter() {
                // The same name in two joined tables is one thing to type.
                if !columns.insert(&column.name) {
                    continue;
                }
                let kind = ProposalKind::Column {
                    data_type: column.column_type.name.clone(),
                    table: table.clone(),
                };
                proposals.push(Candidate::new(kind, &column.name, &self.identifier(&column.name)));
            }
        }
        if matches!(self.scope, CompletionScope::Objects { schema: None }) {
            for schema in answer.schemas.iter().flat_map(|schemas| schemas.iter()) {
                if !schema.is_system {
                    proposals.push(Candidate::new(
                        ProposalKind::Schema,
                        &schema.name,
                        &self.identifier(&schema.name),
                    ));
                }
            }
        }
        let general = matches!(self.scope, CompletionScope::General { .. });
        for object in answer.objects.iter().flat_map(|objects| objects.iter()) {
            if let Some(proposal) = self.object(object, general) {
                proposals.push(proposal);
            }
        }
        proposals.extend(self.snippets.iter().cloned());
        if general {
            proposals.extend(self.grammar.keywords().map(Candidate::keyword));
        }
        proposals
    }

    /// A relation anywhere a table goes; a function only where an
    /// expression can go.
    fn object(&self, object: &ObjectInfo, general: bool) -> Option<Candidate> {
        let kind = ProposalKind::for_object(object.kind)?;
        if kind == ProposalKind::Function && !general {
            return None;
        }
        Some(Candidate::new(kind, &object.name, &self.identifier(&object.name)))
    }

    /// `name` as the connection's dialect writes it, quoted only when
    /// it would read as something else bare.
    fn identifier(&self, name: &str) -> String {
        match &self.dialect {
            Some(dialect) if !self.grammar.is_bare_identifier(name) => dialect.quote_identifier(name),
            _ => name.to_owned(),
        }
    }
}

/// The part of `buffer` a completion at `word_start` reads: all of an
/// ordinary buffer, and the lines around the cursor in a large one.
pub fn context_bounds(buffer: &gtk4::TextBuffer, word_start: i32) -> (gtk4::TextIter, gtk4::TextIter) {
    let from = word_start.saturating_sub(CONTEXT_BEFORE).max(0);
    let mut start = buffer.iter_at_offset(from);
    let mut line = buffer.iter_at_offset(from);
    // A window that opens mid-line would cut a word in two.
    if from > 0 && line.forward_line() && line.offset() <= word_start {
        start = line;
    }
    let end = buffer.iter_at_offset(word_start.saturating_add(CONTEXT_AFTER));
    (start, end)
}

/// What a column of the list shows for `proposal`, beside its icon and
/// name.
pub fn column_text(proposal: &SqlProposal, column: CompletionColumn) -> Option<String> {
    match (proposal.kind(), column) {
        (ProposalKind::Column { data_type, .. }, CompletionColumn::After) => Some(data_type.clone()),
        (ProposalKind::Column { table, .. }, CompletionColumn::Comment) => Some(match &table.schema {
            Some(schema) => format!("{schema}.{}", table.name),
            None => table.name.clone(),
        }),
        // The row shows what the trigger writes; the list's footer shows
        // the longer description for the selected one.
        (ProposalKind::Snippet(snippet), CompletionColumn::After) => snippet.name.clone(),
        (ProposalKind::Snippet(snippet), CompletionColumn::Comment) => snippet.description.clone(),
        _ => None,
    }
}

/// Replace the word between `begin` and `end` with `text`, as one step
/// Ctrl+Z takes back. A cursor inside a word replaces all of it.
pub fn replace_word(buffer: &gtk4::TextBuffer, mut begin: gtk4::TextIter, mut end: gtk4::TextIter, text: &str) {
    extend_over_word(&mut end);
    buffer.begin_user_action();
    buffer.delete(&mut begin, &mut end);
    buffer.insert(&mut begin, text);
    buffer.end_user_action();
}

/// Replace the word between `begin` and `end` with `snippet`, whose
/// first stop the view then selects, as GtkSourceView's own snippet
/// completion does.
pub fn replace_word_with_snippet(
    view: &sourceview5::View,
    snippet: &sourceview5::Snippet,
    mut begin: gtk4::TextIter,
    mut end: gtk4::TextIter,
) {
    let buffer = view.buffer();
    extend_over_word(&mut end);
    buffer.begin_user_action();
    buffer.delete(&mut begin, &mut end);
    view.push_snippet(snippet, Some(&mut begin));
    buffer.end_user_action();
}

fn extend_over_word(end: &mut gtk4::TextIter) {
    while end.char().is_alphanumeric() || end.char() == '_' {
        if !end.forward_char() {
            break;
        }
    }
}
