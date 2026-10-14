use gtk4::prelude::*;

use super::WorkspaceModel;

impl WorkspaceModel {
    pub(super) fn set_row_op_in_flight(&self, in_flight: bool) {
        self.row_op_spinner.set_visible(in_flight);
    }

    pub(super) fn on_copy_text(&self, text: String) {
        crate::ui::clipboard::copy_text(&self.toast_overlay, text, |message| self.show_toast(message));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::DeliverInput;
    use crate::test_support::{descendants, drain_main_context};
    use crate::ui::session_window::tests::TestWindow;
    use crate::ui::workspace::WorkspaceInput;

    #[gtk4::test]
    fn a_copy_with_a_nul_says_so_and_leaves_the_clipboard_alone() {
        let test = TestWindow::connected("CopyNul");
        let clipboard = test.window.clipboard();
        clipboard.set_text("before");
        let input = test.workspace().input().expect("the workspace's input");

        input.deliver(WorkspaceInput::CopyText("a\0b".to_owned()));
        drain_main_context();

        assert_eq!(local_text(&clipboard).as_deref(), Some("before"));
        let refusal = crate::ui::clipboard::ClipboardError::ContainsNul.message();
        assert!(
            descendants(&test.workspace())
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
                .any(|label| label.label() == refusal),
            "no toast said why"
        );

        input.deliver(WorkspaceInput::CopyText("a\tb".to_owned()));
        drain_main_context();
        assert_eq!(local_text(&clipboard).as_deref(), Some("a\tb"));
    }

    fn local_text(clipboard: &gtk4::gdk::Clipboard) -> Option<String> {
        clipboard.content()?.value(String::static_type()).ok()?.get().ok()
    }
}
