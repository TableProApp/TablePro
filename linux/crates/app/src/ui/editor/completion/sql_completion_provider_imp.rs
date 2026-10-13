use std::cell::{OnceCell, RefCell};
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::subclass::prelude::*;
use sourceview5::{CompletionCell, CompletionColumn, CompletionContext, CompletionProposal};

use super::fuzzy;
use super::sql_completion_provider::{ProviderDeps, column_text, replace_word};
use super::sql_proposal::SqlProposal;

/// Ahead of the document's own words.
const PRIORITY: i32 = 100;

#[derive(Default)]
pub struct SqlCompletionProvider {
    pub deps: OnceCell<ProviderDeps>,
    /// The casefolded word typed so far, which the list filters on.
    pub needle: Rc<RefCell<String>>,
}

#[glib::object_subclass]
impl ObjectSubclass for SqlCompletionProvider {
    const NAME: &'static str = "TableProSqlCompletionProvider";
    type Type = super::sql_completion_provider::SqlCompletionProvider;
    type Interfaces = (sourceview5::CompletionProvider,);
}

impl ObjectImpl for SqlCompletionProvider {}

impl CompletionProviderImpl for SqlCompletionProvider {
    fn title(&self) -> Option<glib::GString> {
        Some(crate::i18n::pgettext("completion group", "Database").into())
    }

    fn priority(&self, _context: &CompletionContext) -> i32 {
        PRIORITY
    }

    fn is_trigger(&self, _iter: &gtk4::TextIter, c: char) -> bool {
        c == '.'
    }

    fn populate_future(
        &self,
        context: &CompletionContext,
    ) -> Pin<Box<dyn Future<Output = Result<gio::ListModel, glib::Error>>>> {
        let provider = self.obj().clone();
        let context = context.clone();
        Box::pin(async move {
            let (Some(buffer), Some((begin, _))) = (context.buffer(), context.bounds()) else {
                return Ok(provider.empty());
            };
            let word = context.word();
            Ok(provider.proposals(buffer.upcast_ref(), begin.offset(), &word).await)
        })
    }

    fn refilter(&self, context: &CompletionContext, model: &gio::ListModel) {
        self.obj().refilter(&context.word(), model);
    }

    fn display(&self, context: &CompletionContext, proposal: &CompletionProposal, cell: &CompletionCell) {
        let Some(proposal) = proposal.downcast_ref::<SqlProposal>() else {
            return;
        };
        let word = context.word();
        match cell.column() {
            CompletionColumn::Icon => match proposal.kind().icon_name() {
                Some(icon) => cell.set_icon_name(icon),
                None => cell.set_text(None),
            },
            CompletionColumn::TypedText => {
                let text = proposal.shown_text(&word);
                match fuzzy::highlight(&text, &fuzzy::casefold(&word)) {
                    Some(attrs) => cell.set_text_with_attributes(&text, &attrs),
                    None => cell.set_text(Some(&text)),
                }
            }
            column => cell.set_text(column_text(proposal, column).as_deref()),
        }
    }

    fn activate(&self, context: &CompletionContext, proposal: &CompletionProposal) {
        let (Some(proposal), Some(buffer), Some((begin, end))) = (
            proposal.downcast_ref::<SqlProposal>(),
            context.buffer(),
            context.bounds(),
        ) else {
            return;
        };
        replace_word(buffer.upcast_ref(), begin, end, &proposal.insert_text(&context.word()));
    }
}
