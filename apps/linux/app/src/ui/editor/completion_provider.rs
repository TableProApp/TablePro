mod model;

use std::cell::{OnceCell, RefCell};
use std::rc::Rc;

use glib::subclass::prelude::*;
use relm4::gtk::{self, gio, glib};
use sourceview5::prelude::*;
use sourceview5::subclass::prelude::*;

use super::completion::{SchemaIndex, SchemaRequest};
use super::completion_proposals::candidates_with;

struct Insertion {
    label: String,
    sql: String,
    source: Rc<str>,
    cursor: i32,
    range: std::ops::Range<usize>,
    request: SchemaRequest,
}

mod proposal {
    use super::*;

    #[derive(Default)]
    pub struct Proposal {
        pub(super) insertion: OnceCell<Insertion>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Proposal {
        const NAME: &str = "BookieSqlCompletionProposal";
        type Type = super::Proposal;
        type Interfaces = (sourceview5::CompletionProposal,);
    }

    impl ObjectImpl for Proposal {}
    impl CompletionProposalImpl for Proposal {}
}

glib::wrapper! {
    pub struct Proposal(ObjectSubclass<proposal::Proposal>) @implements sourceview5::CompletionProposal;
}

mod provider {
    use super::*;

    #[derive(Default)]
    pub struct Provider {
        pub index: RefCell<Rc<RefCell<SchemaIndex>>>,
        pub(crate) lexing: RefCell<super::super::session_lexing::KnownLexing>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Provider {
        const NAME: &str = "BookieSqlCompletionProvider";
        type Type = super::Provider;
        type Interfaces = (sourceview5::CompletionProvider,);
    }

    impl ObjectImpl for Provider {}

    impl CompletionProviderImpl for Provider {
        fn title(&self) -> Option<glib::GString> {
            Some("SQL".into())
        }

        fn populate(&self, context: &sourceview5::CompletionContext) -> Result<gio::ListModel, glib::Error> {
            Ok(self.obj().model(context).upcast())
        }

        fn populate_future(
            &self,
            context: &sourceview5::CompletionContext,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<gio::ListModel, glib::Error>>>> {
            let model = self.obj().model(context);
            Box::pin(async move { Ok(model.upcast()) })
        }

        fn refilter(&self, context: &sourceview5::CompletionContext, _model: &gio::ListModel) {
            context.set_proposals_for_provider(&*self.obj(), Some(&self.obj().model(context)));
        }

        fn activate(&self, context: &sourceview5::CompletionContext, proposal: &sourceview5::CompletionProposal) {
            self.obj().insert(context, proposal);
        }

        fn display(
            &self,
            _context: &sourceview5::CompletionContext,
            proposal: &sourceview5::CompletionProposal,
            cell: &sourceview5::CompletionCell,
        ) {
            let Some(insertion) = proposal
                .downcast_ref::<super::Proposal>()
                .and_then(|proposal| proposal.imp().insertion.get())
            else {
                return;
            };
            match cell.column() {
                sourceview5::CompletionColumn::TypedText => cell.set_text(Some(&insertion.label)),
                sourceview5::CompletionColumn::Details => cell.set_text(Some(&insertion.sql)),
                _ => cell.set_text(None),
            }
        }

        fn is_trigger(&self, _iter: &gtk::TextIter, character: char) -> bool {
            character == '.'
        }
    }
}

glib::wrapper! {
    pub struct Provider(ObjectSubclass<provider::Provider>) @implements sourceview5::CompletionProvider;
}

pub(super) fn install(index: Rc<RefCell<SchemaIndex>>, lexing: super::session_lexing::KnownLexing) -> Provider {
    let provider: Provider = glib::Object::new();
    provider.imp().index.replace(index);
    provider.imp().lexing.replace(lexing);
    provider
}

impl Provider {
    fn model(&self, context: &sourceview5::CompletionContext) -> model::ProposalModel {
        let Some(buffer) = context.buffer() else {
            return glib::Object::new();
        };
        let Some(text) = super::sql_text::analysis_text(buffer.upcast_ref()) else {
            return glib::Object::new();
        };
        let source: Rc<str> = text.as_str().into();
        let cursor = super::statement_cursor::cursor_byte_offset(
            &source,
            buffer.iter_at_mark(&buffer.get_insert()).offset() as usize,
        );
        let index = self.imp().index.borrow();
        let Ok(index) = index.try_borrow() else {
            return glib::Object::new();
        };
        let settings = self.imp().lexing.borrow().settings();
        let candidates = candidates_with(&source, cursor, &index, settings);
        model::ProposalModel::new(
            candidates,
            source,
            buffer.iter_at_mark(&buffer.get_insert()).offset(),
            index.request(String::new()),
        )
    }

    fn insert(&self, context: &sourceview5::CompletionContext, proposal: &sourceview5::CompletionProposal) {
        let Some(insertion) = proposal
            .downcast_ref::<Proposal>()
            .and_then(|proposal| proposal.imp().insertion.get())
        else {
            return;
        };
        let Some(buffer) = context.buffer() else {
            return;
        };
        let index = self.imp().index.borrow();
        let Ok(index) = index.try_borrow() else {
            return;
        };
        let Some(text) = super::sql_text::analysis_text(buffer.upcast_ref()) else {
            return;
        };
        if !index.accepts(&insertion.request)
            || text.as_str() != insertion.source.as_ref()
            || buffer.iter_at_mark(&buffer.get_insert()).offset() != insertion.cursor
        {
            return;
        }
        drop(index);
        let start = insertion.source[..insertion.range.start].chars().count() as i32;
        let end = insertion.source[..insertion.range.end].chars().count() as i32;
        let mut start = buffer.iter_at_offset(start);
        let mut end = buffer.iter_at_offset(end);
        buffer.begin_user_action();
        buffer.delete(&mut start, &mut end);
        buffer.insert(&mut start, &insertion.sql);
        buffer.end_user_action();
    }
}

pub(super) fn build_completion_refresh(
    view: sourceview5::View,
    schema_index: std::rc::Rc<std::cell::RefCell<SchemaIndex>>,
    known_lexing: super::session_lexing::KnownLexing,
    sender: relm4::ComponentSender<super::SqlEditor>,
) -> std::rc::Rc<dyn Fn()> {
    let view = view.downgrade();
    std::rc::Rc::new(move || {
        let Some(view) = view.upgrade() else {
            return;
        };
        let buffer = view.buffer();
        let Some(sql) = super::sql_text::analysis_text(&buffer) else {
            return;
        };
        let cursor_chars = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
        let cursor_byte = super::statement_cursor::cursor_byte_offset(&sql, cursor_chars);
        let Ok(index) = schema_index.try_borrow() else {
            return;
        };
        let missing: Vec<String> =
            super::completion::referenced_tables_with(&sql, cursor_byte, index.grammar, known_lexing.settings())
                .into_iter()
                .filter(|table| !index.knows_columns(table))
                .collect();
        drop(index);
        if !missing.is_empty() {
            let _ = sender.output(super::SqlEditorOutput::NeedColumns(missing));
        }
    })
}

#[cfg(test)]
#[path = "completion_provider/tests.rs"]
mod tests;
