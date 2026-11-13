use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::ShareLimits;

use super::ShareDialog;
use super::sheet_view::{self, SheetPage};
use crate::i18n::{gettext, gettext_f};
use crate::ui::icons;

pub(super) fn page_widget(dialog: &ShareDialog, page: &SheetPage) -> gtk::Widget {
    match page {
        SheetPage::Unavailable(reason) => status(icons::DIALOG_WARNING, &gettext("Accounts Unavailable"), reason, None),
        SheetPage::SignedOut => status(
            icons::ACCOUNT,
            "",
            &gettext("Sign in to your TablePro account to share links."),
            Some(button(dialog, &gettext("Sign In…"), true, ShareDialog::sign_in)),
        ),
        SheetPage::SigningIn => {
            let waiting = gtk::Box::builder()
                .orientation(gtk::Orientation::Vertical)
                .spacing(12)
                .halign(gtk::Align::Center)
                .build();
            waiting.append(&adw::Spinner::builder().width_request(32).height_request(32).build());
            waiting.append(&button(dialog, &gettext("Cancel"), false, ShareDialog::cancel_sign_in));
            status(
                icons::ACCOUNT,
                "",
                &gettext("Finish signing in in the web browser that opened."),
                Some(waiting.upcast()),
            )
        }
        SheetPage::Loading | SheetPage::Form => adw::Spinner::builder()
            .width_request(32)
            .height_request(32)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .vexpand(true)
            .build()
            .upcast(),
        SheetPage::Failed(message) => status(
            icons::NETWORK_ERROR,
            "",
            message,
            Some(button(dialog, &gettext("Try Again"), false, ShareDialog::load_limits)),
        ),
        SheetPage::Unverified => status(
            icons::ACCOUNT,
            "",
            &gettext("Verify your email address to share links."),
            Some(button(
                dialog,
                &gettext("Open Account"),
                true,
                ShareDialog::open_account,
            )),
        ),
        SheetPage::Disabled => status(
            icons::ACTION_UNAVAILABLE,
            "",
            &gettext("Sharing is turned off for this account."),
            None,
        ),
        SheetPage::AtLimit => at_limit(dialog),
        SheetPage::Created(url) => created(dialog, url),
    }
}

fn status(icon: &str, title: &str, body: &str, child: Option<gtk::Widget>) -> gtk::Widget {
    let page = adw::StatusPage::builder()
        .icon_name(icon)
        .title(title)
        .vexpand(true)
        .build();
    // The body can quote the server or a path, which is never markup.
    let body = gtk::Label::builder()
        .label(body)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::WordChar)
        .justify(gtk::Justification::Center)
        .build();
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .build();
    content.append(&body);
    if let Some(child) = child {
        content.append(&child);
    }
    page.set_child(Some(&content));
    page.add_css_class("compact");
    page.upcast()
}

fn button(dialog: &ShareDialog, label: &str, suggested: bool, act: fn(&ShareDialog)) -> gtk::Widget {
    let button = gtk::Button::builder()
        .label(label)
        .halign(gtk::Align::Center)
        .css_classes(["pill"])
        .build();
    if suggested {
        button.add_css_class("suggested-action");
    }
    let dialog = dialog.downgrade();
    button.connect_clicked(move |_| {
        if let Some(dialog) = dialog.upgrade() {
            act(&dialog);
        }
    });
    button.upcast()
}

fn at_limit(dialog: &ShareDialog) -> gtk::Widget {
    let imp = dialog.imp();
    let page = adw::PreferencesPage::new();
    let limits = imp.limits.borrow();
    let Some(limits) = limits.as_ref() else {
        return page.upcast();
    };
    let group = adw::PreferencesGroup::builder()
        .description(description(limits))
        .build();
    let busy = imp.busy.get();
    for row in sheet_view::live_link_rows(&imp.live.borrow()) {
        let shown = adw::ActionRow::builder()
            .title(&row.title)
            .use_markup(false)
            .subtitle(&row.subtitle)
            .build();
        let revoke = gtk::Button::builder()
            .label(gettext("Revoke"))
            .valign(gtk::Align::Center)
            .sensitive(!busy)
            .css_classes(["destructive-action"])
            .build();
        revoke.update_property(&[gtk::accessible::Property::Label(&gettext_f(
            "Revoke {title}",
            &[("title", &row.title)],
        ))]);
        let (dialog, id) = (dialog.downgrade(), row.id.clone());
        revoke.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.revoke(id.clone());
            }
        });
        shown.add_suffix(&revoke);
        group.add(&shown);
    }
    page.add(&group);
    page.upcast()
}

fn description(limits: &ShareLimits) -> String {
    let message = sheet_view::at_limit_message(limits);
    match sheet_view::at_limit_upsell(limits) {
        Some(upsell) => format!("{message} {upsell}"),
        None => message,
    }
}

fn created(dialog: &ShareDialog, url: &str) -> gtk::Widget {
    let link = gtk::Label::builder()
        .label(url)
        .selectable(true)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::Char)
        .justify(gtk::Justification::Center)
        .css_classes(["monospace"])
        .build();
    let copy = gtk::Button::builder()
        .label(gettext("Copy"))
        .css_classes(["pill"])
        .build();
    let open = gtk::Button::builder()
        .label(gettext("Open in Browser"))
        .css_classes(["pill", "suggested-action"])
        .build();
    let weak = dialog.downgrade();
    copy.connect_clicked(move |_| {
        if let Some(dialog) = weak.upgrade() {
            dialog.copy_link();
        }
    });
    let weak = dialog.downgrade();
    open.connect_clicked(move |_| {
        if let Some(dialog) = weak.upgrade() {
            dialog.open_link();
        }
    });
    let buttons = gtk::Box::builder()
        .spacing(12)
        .halign(gtk::Align::Center)
        .homogeneous(true)
        .build();
    buttons.append(&copy);
    buttons.append(&open);
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .build();
    content.append(&link);
    content.append(&buttons);
    let page = adw::StatusPage::builder()
        .icon_name(icons::SUCCESS)
        .title(gettext("Link copied"))
        .child(&content)
        .vexpand(true)
        .build();
    page.add_css_class("compact");
    page.upcast()
}
