use std::cell::{OnceCell, RefCell};
use std::rc::Rc;

use glib::subclass::prelude::*;
use relm4::gtk::{self, gio, glib};
use sourceview5::prelude::*;
use sourceview5::subclass::prelude::*;

use super::completion::{SchemaIndex, SchemaRequest};
use super::completion_proposals::candidates;

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

pub(super) fn install(index: Rc<RefCell<SchemaIndex>>) -> Provider {
    let provider: Provider = glib::Object::new();
    provider.imp().index.replace(index);
    provider
}

impl Provider {
    fn model(&self, context: &sourceview5::CompletionContext) -> gio::ListStore {
        let model = gio::ListStore::new::<Proposal>();
        let Some(buffer) = context.buffer() else {
            return model;
        };
        let (start, end) = buffer.bounds();
        let source: Rc<str> = buffer.text(&start, &end, true).as_str().into();
        let cursor = super::statement_cursor::cursor_byte_offset(
            &source,
            buffer.iter_at_mark(&buffer.get_insert()).offset() as usize,
        );
        let index = self.imp().index.borrow();
        let Ok(index) = index.try_borrow() else {
            return model;
        };
        let candidates = candidates(&source, cursor, &index);
        for (label, sql) in candidates.values {
            let proposal: Proposal = glib::Object::new();
            let _ = proposal.imp().insertion.set(Insertion {
                label,
                sql,
                source: source.clone(),
                cursor: buffer.iter_at_mark(&buffer.get_insert()).offset(),
                range: candidates.range.clone(),
                request: index.request(String::new()),
            });
            model.append(&proposal);
        }
        model
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
        let (start, end) = buffer.bounds();
        if !index.accepts(&insertion.request)
            || buffer.text(&start, &end, true).as_str() != insertion.source.as_ref()
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

#[cfg(test)]
#[path = "completion_provider/tests.rs"]
mod tests;
