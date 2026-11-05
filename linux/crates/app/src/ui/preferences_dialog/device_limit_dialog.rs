use std::cell::{Cell, RefCell};
use std::rc::Rc;

use chrono::Utc;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::{AccountError, AccountStatus, Device, EntitlementProblem};
use tablepro_session::runtime::Tasks;

use super::account_view::{self, DeviceRow, Removal};
use crate::i18n::{gettext, gettext_f};
use crate::services::account_service::AccountHandle;
use crate::ui::error_text::account_error_message;

const CANCEL: &str = "cancel";
const REMOVE: &str = "remove";

// The device's name, and why the plan is not verified yet when the check after the removal failed.
type Removed = dyn Fn(&str, Option<&AccountError>);

// The license's holders, from device_limit_reached; one is removed in place to move the license here.
pub(crate) struct DeviceLimitDialog {
    pub(crate) dialog: adw::Dialog,
    group: adw::PreferencesGroup,
    banner: adw::Banner,
    rows: RefCell<Vec<adw::ActionRow>>,
    holding: RefCell<Vec<Device>>,
    removing: RefCell<Option<String>>,
    handle: AccountHandle,
    tasks: Tasks,
    removed: Box<Removed>,
    following: RefCell<Option<glib::JoinHandle<()>>>,
    closed: Cell<bool>,
}

impl DeviceLimitDialog {
    pub(crate) fn new(
        holding: Vec<Device>,
        handle: AccountHandle,
        tasks: Tasks,
        removed: impl Fn(&str, Option<&AccountError>) + 'static,
    ) -> Rc<Self> {
        let banner = adw::Banner::builder().use_markup(false).revealed(false).build();
        let group = adw::PreferencesGroup::builder()
            .title(gettext("Devices Using the License"))
            .description(gettext(
                "Paid features work on 3 devices at a time. Remove one to use them on this computer. Until then, TablePro works here with the free features.",
            ))
            .build();
        let page = adw::PreferencesPage::new();
        page.add(&group);
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&adw::HeaderBar::new());
        toolbar.add_top_bar(&banner);
        toolbar.set_content(Some(&page));
        let dialog = adw::Dialog::builder()
            .title(gettext("Device Limit Reached"))
            .content_width(520)
            .content_height(460)
            .child(&toolbar)
            .build();
        let this = Rc::new(Self {
            dialog,
            group,
            banner,
            rows: RefCell::new(Vec::new()),
            holding: RefCell::new(holding),
            removing: RefCell::new(None),
            handle,
            tasks,
            removed: Box::new(removed),
            following: RefCell::new(None),
            closed: Cell::new(false),
        });
        this.render();
        this.follow();
        let closing = Rc::downgrade(&this);
        this.dialog.connect_closed(move |_| {
            let Some(this) = closing.upgrade() else {
                return;
            };
            this.closed.set(true);
            if let Some(following) = this.following.take() {
                following.abort();
            }
        });
        this
    }

    #[cfg(test)]
    pub(crate) fn rows(&self) -> Vec<adw::ActionRow> {
        self.rows.borrow().clone()
    }

    #[cfg(test)]
    pub(crate) fn error(&self) -> Option<String> {
        self.banner.is_revealed().then(|| self.banner.title().to_string())
    }

    fn follow(self: &Rc<Self>) {
        let mut status = self.handle.status.clone();
        let this = Rc::downgrade(self);
        let following = glib::spawn_future_local(async move {
            while status.changed().await.is_ok() {
                let holding = status.borrow_and_update().device_limit().map(<[Device]>::to_vec);
                let Some(this) = this.upgrade() else {
                    return;
                };
                match holding {
                    Some(devices) => {
                        this.holding.replace(devices);
                        this.render();
                    }
                    None => {
                        this.close();
                        return;
                    }
                }
            }
        });
        self.following.replace(Some(following));
    }

    fn render(self: &Rc<Self>) {
        for row in self.rows.take() {
            self.group.remove(&row);
        }
        let rows = account_view::limit_devices(&self.holding.borrow(), Utc::now());
        let removing = self.removing.borrow().clone();
        let mut built = Vec::new();
        for device in rows {
            let row = self.row(&device, removing.as_deref());
            self.group.add(&row);
            built.push(row);
        }
        self.rows.replace(built);
    }

    fn row(self: &Rc<Self>, device: &DeviceRow, removing: Option<&str>) -> adw::ActionRow {
        let row = super::account_page::plain_row(&device.name, Some(&device.subtitle));
        match &device.removal {
            Removal::KeptUntil(until) => {
                let label = gtk4::Label::builder().label(until).valign(gtk4::Align::Center).build();
                label.add_css_class("dim-label");
                row.add_suffix(&label);
            }
            Removal::Allowed | Removal::ThisDevice if removing == Some(device.id.as_str()) => {
                row.add_suffix(&adw::Spinner::new());
            }
            Removal::Allowed | Removal::ThisDevice => {
                let button = gtk4::Button::builder()
                    .label(gettext("Remove"))
                    .valign(gtk4::Align::Center)
                    .sensitive(removing.is_none())
                    .build();
                button.update_property(&[gtk4::accessible::Property::Label(&gettext_f(
                    "Remove {name}",
                    &[("name", &device.name)],
                ))]);
                let this = Rc::downgrade(self);
                let (id, name) = (device.id.clone(), device.name.clone());
                button.connect_clicked(move |_| {
                    if let Some(this) = this.upgrade() {
                        this.confirm(id.clone(), name.clone());
                    }
                });
                row.add_suffix(&button);
            }
        }
        row
    }

    // A removal and the status it changes both end the dialog, and a second close is a GLib critical.
    fn close(&self) {
        if !self.closed.replace(true) {
            self.dialog.close();
        }
    }

    fn confirm(self: &Rc<Self>, id: String, name: String) {
        let alert = adw::AlertDialog::new(
            Some(&gettext_f("Remove {name}?", &[("name", &name)])),
            Some(&gettext(
                "TablePro on it signs out the next time it checks in, and this computer takes its license slot.",
            )),
        );
        alert.add_response(CANCEL, &gettext("_Cancel"));
        alert.add_response(REMOVE, &gettext("_Remove"));
        alert.set_response_appearance(REMOVE, adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some(CANCEL));
        alert.set_close_response(CANCEL);
        let this = self.clone();
        glib::spawn_future_local(async move {
            let parent: gtk4::Widget = this.dialog.clone().upcast();
            if crate::workspace::respond(&alert, &parent).await == REMOVE {
                this.remove(id, name).await;
            }
        });
    }

    async fn remove(self: &Rc<Self>, id: String, name: String) {
        let Some(account) = self.handle.account() else {
            return;
        };
        self.banner.set_revealed(false);
        self.removing.replace(Some(id.clone()));
        self.render();
        let removing = self.tasks.spawn_task(async move { account.remove_device(&id).await });
        let removed = removing.await;
        self.removing.replace(None);
        match removed {
            Ok(Ok(())) => {
                (self.removed)(&name, None);
                self.close();
            }
            // The device is gone and only the check after it failed, which the page goes on showing.
            Ok(Err(error)) if refresh_failed(&self.handle.status.borrow()) => {
                (self.removed)(&name, Some(&error));
                self.close();
            }
            Ok(Err(error)) => {
                self.banner.set_title(&account_error_message(&error));
                self.banner.set_revealed(true);
                self.render();
            }
            Err(error) => {
                tracing::warn!(%error, "the device removal did not finish");
                self.render();
            }
        }
    }
}

fn refresh_failed(status: &AccountStatus) -> bool {
    matches!(status, AccountStatus::SignedIn(held) if matches!(held.problem, Some(EntitlementProblem::RefreshFailed(_))))
}
