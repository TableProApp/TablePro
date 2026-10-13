use relm4::adw::prelude::*;
use uuid::Uuid;

use super::App;

impl App {
    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }

    pub(super) fn on_copy_row_as_insert(&self, tab_id: Uuid, row_position: u32) {
        let Some(browse) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.browse_tab())
            .cloned()
        else {
            return;
        };
        let (columns, snapshot, table) = (browse.columns(), browse.snapshot(), browse.table());
        let Some(snapshot) = snapshot else { return };
        let Some(row) = snapshot.rows.get(row_position as usize) else {
            return;
        };
        let Some(dialect) = self.context.active.get().and_then(|session| session.current_dialect()) else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        let result_columns: Vec<_> = columns.iter().map(|column| column.result_column()).collect();
        let sql =
            tablepro_core::export::render_sql_insert(&*dialect, &table, &result_columns, std::slice::from_ref(row));
        let sql = sql.trim_end().to_owned();
        self.window.clipboard().set_text(&sql);
        self.show_toast(&crate::i18n::gettext("INSERT statement copied"));
    }

    pub(super) fn on_copy_to_clipboard(&self, text: String) {
        self.window.clipboard().set_text(&text);
        self.show_toast(&crate::i18n::gettext("Copied to clipboard"));
    }
}
