use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::OperationError;
use tablepro_session::runtime::TaskFailure;

use super::ShareDialog;
use super::sheet_view::SheetPage;
use crate::runtime::spawn_and_deliver;
use crate::services::share_subject::{ShareSubject, SharedRows};
use crate::ui::error_text::{operation_error_message, task_failure_message};

impl ShareDialog {
    pub(super) fn current_subject(&self) -> Option<Arc<ShareSubject>> {
        self.imp().subject.borrow().clone()
    }

    // A table tab hands over its view, whose rows are read once the plan says how many.
    pub(super) fn rows_to_read(&self) -> bool {
        self.current_subject()
            .is_some_and(|subject| subject.table.is_some() && subject.rows.is_none())
    }

    pub(super) fn read_table(&self, max_rows: u64) {
        let imp = self.imp();
        let (Some(deps), Some(table)) = (
            imp.deps.get(),
            self.current_subject().and_then(|subject| subject.table.clone()),
        ) else {
            return;
        };
        let read = imp.read.get() + 1;
        imp.read.set(read);
        self.show(SheetPage::Loading);
        let dialog = self.downgrade();
        spawn_and_deliver(&deps.tasks, Arc::new(table).read(max_rows), move |result| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.table_read(read, result);
            }
        });
    }

    fn table_read(&self, read: u64, result: Result<Result<SharedRows, OperationError>, TaskFailure>) {
        let imp = self.imp();
        if imp.read.get() != read {
            return;
        }
        match result {
            Ok(Ok(rows)) => {
                let read = self.current_subject().map(|subject| ShareSubject {
                    rows: Some(rows),
                    ..(*subject).clone()
                });
                imp.subject.replace(read.map(Arc::new));
                self.show(SheetPage::Form);
            }
            Ok(Err(error)) => self.show(SheetPage::Failed(operation_error_message(&error))),
            Err(failure) => self.show(SheetPage::Failed(task_failure_message(&failure))),
        }
    }

    // A team link counts against the team, so its limits and its links are read again for it.
    pub(super) fn choose_target(&self, team: Option<String>) {
        let imp = self.imp();
        if *imp.target.borrow() == team {
            return;
        }
        imp.target.replace(team);
        self.load_limits();
    }
}
