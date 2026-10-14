//! A column of the draft, as the Columns list holds it.

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::ddl::DraftColumn;

use super::draft_column_object_imp as imp;

glib::wrapper! {
    /// The row bound to a column follows its `name` and `summary`, and
    /// the tab finds the column by this object rather than by position.
    pub struct DraftColumnObject(ObjectSubclass<imp::DraftColumnObject>);
}

/// Default text the engine's parser refused. The column keeps the
/// default it had, and Save waits until the text parses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UnparsedDefault {
    pub text: String,
    pub error: String,
}

impl DraftColumnObject {
    pub(crate) fn new(column: DraftColumn) -> Self {
        let object: Self = glib::Object::new();
        object.imp().column.replace(column);
        object
    }

    pub(crate) fn column(&self) -> DraftColumn {
        self.imp().column.borrow().clone()
    }

    /// Change the column, and tell the rows bound to it when its name or
    /// summary changed.
    pub(crate) fn update(&self, change: impl FnOnce(&mut DraftColumn)) {
        let (name, summary) = (self.name(), self.summary());
        change(&mut self.imp().column.borrow_mut());
        // The borrow has ended by now, since a bound row reads the
        // column back as it hears of the change.
        if self.name() != name {
            self.notify_name();
        }
        if self.summary() != summary {
            self.notify_summary();
        }
    }

    pub(crate) fn unparsed_default(&self) -> Option<UnparsedDefault> {
        self.imp().unparsed_default.borrow().clone()
    }

    pub(crate) fn set_unparsed_default(&self, unparsed: Option<UnparsedDefault>) {
        if *self.imp().unparsed_default.borrow() == unparsed {
            return;
        }
        self.imp().unparsed_default.replace(unparsed);
        self.notify_default_error();
    }
}

/// The collapsed row's summary, such as `varchar(255) · NOT NULL ·
/// Primary key`.
pub(super) fn column_summary(column: &DraftColumn) -> String {
    let mut parts: Vec<String> = Vec::new();
    let type_text = column.column_type.text();
    if !type_text.is_empty() {
        parts.push(type_text.to_owned());
    }
    parts.push(if column.nullable {
        crate::i18n::gettext("nullable")
    } else {
        crate::i18n::gettext("NOT NULL")
    });
    if column.primary_key {
        parts.push(crate::i18n::gettext("Primary key"));
    }
    if column.auto_increment {
        parts.push(crate::i18n::gettext("auto-increment"));
    }
    parts.join(" · ")
}
