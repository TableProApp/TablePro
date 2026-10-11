use relm4::ComponentSender;
use tablepro_core::Value;

use super::{BrowseTab, BrowseTabOutput};

impl BrowseTab {
    pub(super) fn request_cell_value(
        &mut self,
        col_index: usize,
        column_name: String,
        row_key: Vec<Value>,
        sender: ComponentSender<Self>,
    ) {
        let request = self.cell_value_requests.begin();
        let _ = sender.output(BrowseTabOutput::FetchCellValue {
            request,
            col_index,
            column_name,
            row_key,
        });
    }

    pub(super) fn show_cell_value(
        &self,
        request: super::BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        value: Value,
    ) {
        if self.cell_value_requests.accepts(request)
            && let Some(view) = self.current_column_view.as_ref()
            && self
                .current_columns
                .get(col_index)
                .is_some_and(|column| column.name == column_name)
        {
            crate::ui::grid::present_value_viewer(
                view,
                &column_name,
                &value,
                crate::ui::grid::value_to_full_edit_text(&value),
            );
        }
    }
}
