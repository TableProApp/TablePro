use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;
use tablepro_account::{Account, AccountError, SharedLink, share_token_from_link};
use tablepro_session::runtime::TaskFailure;

use super::TableProApplication;
use super::open_files::Placement;
use super::open_links::{CANCEL, OPEN};
use crate::i18n::gettext;
use crate::services::account_service::AccountStart;
use crate::ui::error_text::{account_unavailable_message, shared_link_message};
use crate::ui::{SessionWindow, SessionWindowInput};

type Fetched = Result<Result<SharedLink, AccountError>, TaskFailure>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PasswordAsk {
    First,
    AfterWrongOne,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum SharedOutcome {
    Open { title: String, sql: String },
    AskPassword(PasswordAsk),
    Say(String),
}

pub(super) fn outcome(fetched: Result<SharedLink, AccountError>) -> SharedOutcome {
    match fetched {
        // Anyone can write a link, and GTK refuses text with a NUL in it.
        Ok(SharedLink {
            title, sql: Some(sql), ..
        }) if !sql.replace('\0', "").trim().is_empty() => SharedOutcome::Open {
            title: title.replace('\0', ""),
            sql: sql.replace('\0', ""),
        },
        // Hidden, or a result shared without SQL: an empty editor tab would open nothing anyone asked for.
        Ok(SharedLink { .. }) => SharedOutcome::Say(gettext(
            "This shared result hides its SQL, so there is nothing to open.",
        )),
        Err(error) => match error.code() {
            "account.share_password_required" => SharedOutcome::AskPassword(PasswordAsk::First),
            "account.share_password_wrong" => SharedOutcome::AskPassword(PasswordAsk::AfterWrongOne),
            _ => SharedOutcome::Say(shared_link_message(&error)),
        },
    }
}

impl TableProApplication {
    pub(super) fn open_share_link(&self, link: &str, placement: Placement) {
        let Some(token) = share_token_from_link(link) else {
            tracing::warn!("a share link without a token TablePro reads");
            return self.say_about_share(&gettext("This shared link is no longer available."));
        };
        let Some(services) = self.services() else {
            tracing::warn!("no share link opened: the application has no services");
            return;
        };
        let mut start = services.account().start.clone();
        // An instance D-Bus started for this link would otherwise exit before its window opens.
        let hold = self.hold();
        let app = self.downgrade();
        glib::spawn_future_local(async move {
            // The account starts on the runtime at launch, which a link can beat.
            let started = loop {
                let current = start.borrow_and_update().clone();
                if !matches!(current, AccountStart::Starting) || start.changed().await.is_err() {
                    break current;
                }
            };
            if let Some(app) = app.upgrade() {
                match started {
                    AccountStart::Ready(account) => app.fetch_shared(account, token, None, placement),
                    other => {
                        let reason = account_unavailable_message(&other)
                            .unwrap_or_else(|| gettext("This shared link is no longer available."));
                        app.say_about_share(&reason);
                    }
                }
            }
            drop(hold);
        });
    }

    fn fetch_shared(&self, account: Account, token: String, password: Option<SecretString>, placement: Placement) {
        let Some(services) = self.services() else {
            return;
        };
        let hold = self.hold();
        let app = self.downgrade();
        let fetching = account.clone();
        let asked = token.clone();
        crate::runtime::spawn_and_deliver(
            &services.tasks,
            async move { fetching.fetch_shared(&asked, password.as_ref()).await },
            move |fetched: Fetched| {
                if let Some(app) = app.upgrade() {
                    app.shared_fetched(account, token, fetched, placement);
                }
                drop(hold);
            },
        );
    }

    fn shared_fetched(&self, account: Account, token: String, fetched: Fetched, placement: Placement) {
        let fetched = match fetched {
            Ok(fetched) => fetched,
            Err(failure) => Err(AccountError::Protocol(failure.to_string())),
        };
        match outcome(fetched) {
            SharedOutcome::Open { title, sql } => self.place_shared_sql(title, sql, placement),
            SharedOutcome::AskPassword(ask) => {
                let app = self.downgrade();
                glib::spawn_future_local(async move {
                    if let Some(app) = app.upgrade() {
                        app.ask_share_password(account, token, ask, placement).await;
                    }
                });
            }
            SharedOutcome::Say(message) => self.say_about_share(&message),
        }
    }

    async fn ask_share_password(&self, account: Account, token: String, ask: PasswordAsk, placement: Placement) {
        let Some(parent) = self.share_window() else {
            return;
        };
        let (dialog, entry) = password_dialog(ask);
        let hold = self.hold();
        let answer = crate::workspace::respond(&dialog, parent.upcast_ref()).await;
        let password = entry.text().to_string();
        if answer == OPEN && !password.is_empty() {
            self.fetch_shared(account, token, Some(SecretString::from(password)), placement);
        }
        drop(hold);
    }

    fn say_about_share(&self, message: &str) {
        match self.share_window() {
            Some(window) => {
                window.send(SessionWindowInput::ShowToast(message.to_owned()));
                window.present();
            }
            None => tracing::warn!("no window to say why a share link did not open"),
        }
    }

    // A word about a link goes on a window already open; a picker opens only when there is none.
    fn share_window(&self) -> Option<SessionWindow> {
        self.active_window()
            .and_downcast::<SessionWindow>()
            .or_else(|| {
                self.windows()
                    .into_iter()
                    .find_map(|window| window.downcast::<SessionWindow>().ok())
            })
            .or_else(|| {
                self.open_window(super::WindowLaunch::Picker)
                    .and_downcast::<SessionWindow>()
            })
    }
}

// Enter opens with the typed password; Escape and closing cancel.
pub(super) fn password_dialog(ask: PasswordAsk) -> (adw::AlertDialog, adw::PasswordEntryRow) {
    let body = match ask {
        PasswordAsk::First => gettext("This link is password protected."),
        PasswordAsk::AfterWrongOne => gettext("That password is not correct."),
    };
    let dialog = adw::AlertDialog::new(Some(&gettext("Open Shared Link")), Some(&body));
    let entry = adw::PasswordEntryRow::builder()
        .title(gettext("Password"))
        .activates_default(true)
        .build();
    let group = adw::PreferencesGroup::new();
    group.add(&entry);
    dialog.set_extra_child(Some(&group));
    dialog.add_response(CANCEL, &gettext("_Cancel"));
    dialog.add_response(OPEN, &gettext("_Open"));
    dialog.set_response_appearance(OPEN, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(OPEN));
    dialog.set_close_response(CANCEL);
    // A password may be spaces, so only an empty one keeps Open off.
    dialog.set_response_enabled(OPEN, false);
    let waiting = dialog.downgrade();
    entry.connect_changed(move |entry| {
        if let Some(dialog) = waiting.upgrade() {
            dialog.set_response_enabled(OPEN, !entry.text().is_empty());
        }
    });
    dialog.set_focus(Some(&entry));
    (dialog, entry)
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    fn link(sql: Option<&str>) -> SharedLink {
        SharedLink {
            kind: "query".to_owned(),
            title: "Orders".to_owned(),
            note: String::new(),
            dialect: "postgres".to_owned(),
            sql: sql.map(str::to_owned),
            created_at: Utc::now(),
            expires_at: None,
            allow_download: true,
            row_count: None,
            truncated: None,
        }
    }

    fn refused(status: u16, code: &str) -> AccountError {
        AccountError::Refused {
            status,
            code: code.to_owned(),
            detail: String::new(),
        }
    }

    #[test]
    fn a_link_with_sql_opens_it_and_one_that_hides_it_says_so() {
        assert_eq!(
            outcome(Ok(link(Some("SELECT 1")))),
            SharedOutcome::Open {
                title: "Orders".to_owned(),
                sql: "SELECT 1".to_owned()
            }
        );
        assert_eq!(
            outcome(Ok(link(None))),
            SharedOutcome::Say("This shared result hides its SQL, so there is nothing to open.".to_owned())
        );
    }

    #[test]
    fn a_nul_in_a_links_title_or_sql_is_dropped_before_gtk_sees_it() {
        let mut shared = link(Some("SELECT\0 1"));
        shared.title = "Ord\0ers".to_owned();

        assert_eq!(
            outcome(Ok(shared)),
            SharedOutcome::Open {
                title: "Orders".to_owned(),
                sql: "SELECT 1".to_owned()
            }
        );
    }

    #[test]
    fn a_result_shared_with_blank_sql_opens_nothing() {
        for sql in ["", "  \n\t", "\0"] {
            assert_eq!(
                outcome(Ok(link(Some(sql)))),
                SharedOutcome::Say("This shared result hides its SQL, so there is nothing to open.".to_owned()),
                "{sql:?}"
            );
        }
    }

    #[test]
    fn a_password_is_asked_for_and_asked_again_after_a_wrong_one() {
        assert_eq!(
            outcome(Err(refused(401, "share_password_required"))),
            SharedOutcome::AskPassword(PasswordAsk::First)
        );
        assert_eq!(
            outcome(Err(refused(401, "share_password_wrong"))),
            SharedOutcome::AskPassword(PasswordAsk::AfterWrongOne)
        );
    }

    #[test]
    fn a_gone_link_says_it_is_no_longer_available() {
        assert_eq!(
            outcome(Err(refused(404, "not_found"))),
            SharedOutcome::Say("This shared link is no longer available.".to_owned())
        );
    }

    #[gtk4::test]
    fn the_password_dialog_opens_on_enter_once_typed_and_closes_as_cancel() {
        let (dialog, entry) = password_dialog(PasswordAsk::AfterWrongOne);

        assert_eq!(dialog.body(), "That password is not correct.");
        assert_eq!(dialog.default_response().as_deref(), Some(OPEN));
        assert_eq!(dialog.close_response(), CANCEL);
        assert!(!dialog.is_response_enabled(OPEN));
        entry.set_text("hunter2");
        assert!(dialog.is_response_enabled(OPEN));
        assert_eq!(crate::test_support::assert_labelled(&entry), Ok(()));
    }
}
