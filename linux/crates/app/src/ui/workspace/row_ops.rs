use gtk4::prelude::*;

use super::WorkspaceModel;

impl WorkspaceModel {
    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }
}
