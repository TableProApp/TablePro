use gtk4::subclass::prelude::*;
use sourceview5::prelude::*;

use super::RowDetailPane;

impl RowDetailPane {
    pub(in crate::ui::data_grid) fn apply_invisibles(&self, show: bool) {
        let drawer = self.imp().value_view.space_drawer();
        drawer.set_types_for_locations(
            sourceview5::SpaceLocationFlags::ALL,
            sourceview5::SpaceTypeFlags::SPACE
                | sourceview5::SpaceTypeFlags::TAB
                | sourceview5::SpaceTypeFlags::NEWLINE
                | sourceview5::SpaceTypeFlags::NBSP,
        );
        drawer.set_enable_matrix(show);
    }
}
