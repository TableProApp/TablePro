use relm4::adw::prelude::*;

use super::ConnectDialog;
use super::form::{EndpointFormState, local_socket_options, resolved_socket_path, socket_directory_is_valid};
use super::toggle_error;

impl ConnectDialog {
    pub(super) fn local_socket_is_file(&self) -> bool {
        self.drivers
            .get(self.driver_combo.selected() as usize)
            .is_some_and(|driver| driver.id == "mysql")
    }

    pub(super) fn configure_socket_field(&self, driver_id: &str) {
        if driver_id == "mysql" {
            self.socket_dir.set_title(&crate::tr!("Socket path"));
            if self.socket_dir.text() == "/run/postgresql" {
                self.socket_dir.set_text("/run/mysqld/mysqld.sock");
            }
            return;
        }
        self.socket_dir.set_title(&crate::tr!("Socket directory"));
        if self.socket_dir.text() == "/run/mysqld/mysqld.sock" {
            self.socket_dir.set_text("/run/postgresql");
        }
    }

    pub(super) fn refresh_socket_path(&self, selected: bool) {
        let text = self.socket_dir.text();
        toggle_error(&self.socket_dir, selected && !socket_directory_is_valid(text.as_str()));
        let path = if self.local_socket_is_file() {
            std::path::PathBuf::from(text.as_str())
        } else {
            resolved_socket_path(text.as_str(), self.port.value() as u16)
        };
        self.resolved_socket.set_subtitle(&path.display().to_string());
    }

    pub(super) fn apply_socket_visibility(&self, endpoint: EndpointFormState) {
        let selected = endpoint.uses_local_socket();
        self.port_row
            .set_visible(endpoint.shows_port() && !(selected && self.local_socket_is_file()));
        self.socket_dir.set_visible(endpoint.shows_socket_rows());
        self.resolved_socket
            .set_visible(endpoint.shows_socket_rows() && !self.local_socket_is_file());
    }

    pub(super) fn selected_socket_options(
        &self,
        driver_id: &str,
        selected: bool,
    ) -> (Option<std::path::PathBuf>, Option<std::path::PathBuf>) {
        if selected {
            local_socket_options(driver_id, self.socket_dir.text().as_str())
        } else {
            (None, None)
        }
    }
}
