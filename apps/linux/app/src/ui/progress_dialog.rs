use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tokio_util::sync::CancellationToken;

pub(crate) struct CancellableDialog {
    dialog: adw::Dialog,
    cancel: CancellationToken,
}

impl CancellableDialog {
    pub(crate) fn present(parent: &adw::ApplicationWindow, title: &str, body: &[&gtk::Widget]) -> Self {
        let cancel = CancellationToken::new();
        let stop = gtk::Button::with_label(&crate::tr!("Cancel"));
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .margin_top(24)
            .margin_bottom(24)
            .margin_start(24)
            .margin_end(24)
            .build();
        for widget in body {
            content.append(*widget);
        }
        content.append(&stop);
        let dialog = adw::Dialog::builder()
            .title(title)
            .content_width(400)
            .child(&content)
            .can_close(false)
            .build();
        stop.connect_clicked({
            let cancel = cancel.clone();
            move |button| {
                cancel.cancel();
                button.set_sensitive(false);
            }
        });
        dialog.present(Some(parent));
        Self { dialog, cancel }
    }

    pub(crate) fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    #[cfg(test)]
    pub(crate) fn dialog(&self) -> &adw::Dialog {
        &self.dialog
    }

    pub(crate) fn close(&self) {
        self.dialog.force_close();
    }
}
