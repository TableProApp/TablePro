use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::CompletionColumn;
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
use super::sql_completion_provider_imp as imp;
use super::sql_proposal::SqlProposal;
use crate::services::active_session::ActiveSession;

glib::wrapper! {
    /// Completes keywords, and the tables, views and columns of the
    /// session's catalog, for what the statement at the cursor asks.
    pub struct SqlCompletionProvider(ObjectSubclass<imp::SqlCompletionProvider>)
        @implements sourceview5::CompletionProvider;
}

pub struct ProviderDeps {
    session: ActiveSession,
    tasks: Tasks,
}

impl SqlCompletionProvider {
    pub fn new(session: ActiveSession, tasks: Tasks) -> Self {
        let provider: Self = glib::Object::new();
        let _ = provider.imp().deps.set(ProviderDeps { session, tasks });
        provider
    }

    /// The proposals for `word`, which starts at character `word_start`
    /// of `buffer`.
    pub async fn proposals(&self, buffer: &gtk4::TextBuffer, word_start: i32, word: &str) -> gio::ListModel {
        self.set_needle(word);
        let store = gio::ListStore::new::<SqlProposal>();
        let model = self.sorted(&store);
        let Some(request) = self.request(buffer, word_start) else {
            return model;
        };
        let answer = match (&request.session, self.imp().deps.get()) {
            (Some(session), Some(deps)) => deps
                .tasks
                .spawn_task(catalog_read::read(session.clone(), request.scope.clone()))
                .await
                .unwrap_or_else(|failure| {
                    tracing::warn!(%failure, "reading the catalog for completion failed");
                    CatalogAnswer::default()
                }),
            _ => CatalogAnswer::default(),
        };
        store.extend_from_slice(&request.proposals(&answer));
        model
    }

    /// Narrow the list to the word now typed.
    pub fn refilter(&self, word: &str, model: &gio::ListModel) {
        self.set_needle(word);
        let Some(sorted) = model.downcast_ref::<gtk4::SortListModel>() else {
            return;
        };
        if let Some(filter) = sorted
            .model()
            .and_downcast::<gtk4::FilterListModel>()
            .and_then(|filtered| filtered.filter())
        {
            filter.changed(gtk4::FilterChange::Different);
        }
        if let Some(sorter) = sorted.sorter() {
            sorter.changed(gtk4::SorterChange::Different);
        }
    }

    pub(super) fn empty(&self) -> gio::ListModel {
        self.sorted(&gio::ListStore::new::<SqlProposal>())
    }

    fn set_needle(&self, word: &str) {
        self.imp().needle.replace(fuzzy::casefold(word));
    }

    /// The store filtered by the needle and sorted closest match first.
    fn sorted(&self, store: &gio::ListStore) -> gio::ListModel {
        let needle = self.imp().needle.clone();
        let filter = gtk4::CustomFilter::new(move |item| {
            let Some(proposal) = item.downcast_ref::<SqlProposal>() else {
                return false;
            };
            let needle = needle.borrow();
            // With nothing typed the matcher ranks by length alone,
            // which would put every short keyword above the columns.
            let priority = if needle.is_empty() {
                Some(0)
            } else {
                fuzzy::fuzzy_match(proposal.label(), &needle)
            };
            match priority {
                Some(priority) => {
                    proposal.set_priority(priority);
                    true
                }
                None => false,
            }
        });
        let sorter =
            gtk4::CustomSorter::new(
                |a, b| match (a.downcast_ref::<SqlProposal>(), b.downcast_ref::<SqlProposal>()) {
                    (Some(a), Some(b)) => a.compare(b).into(),
                    _ => gtk4::Ordering::Equal,
                },
            );
        let filtered = gtk4::FilterListModel::new(Some(store.clone()), Some(filter));
        gtk4::SortListModel::new(Some(filtered), Some(sorter)).upcast()
    }

    fn request(&self, buffer: &gtk4::TextBuffer, word_start: i32) -> Option<Request> {
        let session = self.imp().deps.get().and_then(|deps| deps.session.get());
        let dialect = session.as_ref().and_then(|session| session.current_dialect());
        // With no connection the keywords still complete, and
        // PostgreSQL's reading of the text is the strictest.
        let grammar = dialect
            .as_ref()
            .map_or(SqlGrammar::PostgreSql, |dialect| dialect.grammar());
        let (start, end) = buffer.bounds();
        let text = buffer.text(&start, &end, false);
        let cursor = text_offsets::char_to_byte(&text, usize::try_from(word_start).unwrap_or_default());
        let scope = completion_scope::analyze(&text, cursor, grammar, LexicalSettings::default_for(grammar))?;
        Some(Request {
            scope,
            grammar,
            session,
            dialect,
        })
    }
}

/// One completion's question, read on the GTK thread.
struct Request {
    scope: CompletionScope,
    grammar: SqlGrammar,
    session: Option<Arc<Session>>,
    dialect: Option<Arc<dyn SqlDialect>>,
}

impl Request {
    fn proposals(&self, answer: &CatalogAnswer) -> Vec<SqlProposal> {
        let mut proposals = Vec::new();
        let mut columns: Vec<&str> = Vec::new();
        for (table, list) in &answer.columns {
            for column in list.iter() {
                // The same name in two joined tables is one thing to type.
                if columns.contains(&column.name.as_str()) {
                    continue;
                }
                columns.push(&column.name);
                let kind = ProposalKind::Column {
                    data_type: column.column_type.name.clone(),
                    table: table.clone(),
                };
                proposals.push(SqlProposal::new(kind, &column.name, &self.identifier(&column.name)));
            }
        }
        if matches!(self.scope, CompletionScope::Objects { schema: None }) {
            for schema in answer.schemas.iter().flat_map(|schemas| schemas.iter()) {
                if !schema.is_system {
                    proposals.push(SqlProposal::new(
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
        if general {
            proposals.extend(self.grammar.keywords().map(SqlProposal::keyword));
        }
        proposals
    }

    /// A relation anywhere a table goes; a function only where an
    /// expression can go.
    fn object(&self, object: &ObjectInfo, general: bool) -> Option<SqlProposal> {
        let kind = ProposalKind::for_object(object.kind)?;
        if kind == ProposalKind::Function && !general {
            return None;
        }
        Some(SqlProposal::new(kind, &object.name, &self.identifier(&object.name)))
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

/// What a column of the list shows for `proposal`, beside its icon and
/// name.
pub fn column_text(proposal: &SqlProposal, column: CompletionColumn) -> Option<String> {
    match (proposal.kind(), column) {
        (ProposalKind::Column { data_type, .. }, CompletionColumn::After) => Some(data_type.clone()),
        (ProposalKind::Column { table, .. }, CompletionColumn::Comment) => Some(match &table.schema {
            Some(schema) => format!("{schema}.{}", table.name),
            None => table.name.clone(),
        }),
        _ => None,
    }
}

/// Replace the word between `begin` and `end` with `text`, as one step
/// Ctrl+Z takes back. A cursor inside a word replaces all of it.
pub fn replace_word(buffer: &gtk4::TextBuffer, mut begin: gtk4::TextIter, mut end: gtk4::TextIter, text: &str) {
    while end.char().is_alphanumeric() || end.char() == '_' {
        if !end.forward_char() {
            break;
        }
    }
    buffer.begin_user_action();
    buffer.delete(&mut begin, &mut end);
    buffer.insert(&mut begin, text);
    buffer.end_user_action();
}
