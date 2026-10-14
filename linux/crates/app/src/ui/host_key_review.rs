//! The dialog that shows a refused SSH host key and asks what to do.

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::host_key_failure::{HostKeyFailure, HostKeyFailureKind};

const CANCEL: &str = "cancel";
const CLOSE: &str = "close";
const TRUST: &str = "trust";
const REPLACE: &str = "replace";
const RETRY: &str = "retry";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostKeyReviewOutcome {
    /// Connect, trusting the key shown.
    Trust,
    /// Remove the old key from known_hosts, then connect trusting the
    /// new one.
    Replace,
    /// Connect again answering nothing, for a key the user fixed outside
    /// TablePro.
    Retry,
    Dismissed,
}

/// What the dialog says and offers, worked out before any widget exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostKeyDialogSpec {
    pub heading: String,
    pub body: String,
    pub responses: Vec<HostKeyResponse>,
    pub default: &'static str,
    pub close: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostKeyResponse {
    pub id: &'static str,
    pub label: String,
    pub appearance: adw::ResponseAppearance,
}

impl HostKeyResponse {
    fn new(id: &'static str, label: String, appearance: adw::ResponseAppearance) -> Self {
        Self { id, label, appearance }
    }

    fn cancel() -> Self {
        Self::new(CANCEL, crate::i18n::gettext("Cancel"), adw::ResponseAppearance::Default)
    }

    fn close() -> Self {
        Self::new(CLOSE, crate::i18n::gettext("Close"), adw::ResponseAppearance::Default)
    }

    fn retry() -> Self {
        Self::new(RETRY, crate::i18n::gettext("Retry"), adw::ResponseAppearance::Default)
    }
}

/// Cancel is the default wherever there is something to accept, so
/// Enter never trusts a key or deletes one.
pub(crate) fn host_key_dialog_spec(failure: &HostKeyFailure) -> HostKeyDialogSpec {
    let host = failure.host.as_str();
    match &failure.kind {
        HostKeyFailureKind::Unknown { trust_allowed: true } => {
            let (body, accept) = match failure.fingerprint.is_empty() {
                false => (
                    crate::i18n::gettext_f(
                        "TablePro has not connected to “{host}” before and cannot confirm its identity. Compare the fingerprint with the one from your server administrator.",
                        &[("host", host)],
                    ),
                    crate::i18n::gettext("Trust and Connect"),
                ),
                true => (
                    crate::i18n::gettext_f(
                        "TablePro has not connected to “{host}” before. Connect to see its key’s fingerprint and decide whether to trust it.",
                        &[("host", host)],
                    ),
                    crate::i18n::gettext("Connect"),
                ),
            };
            HostKeyDialogSpec {
                heading: crate::i18n::gettext("Unknown SSH Host"),
                body,
                responses: vec![
                    HostKeyResponse::cancel(),
                    HostKeyResponse::new(TRUST, accept, adw::ResponseAppearance::Suggested),
                ],
                default: CANCEL,
                close: CANCEL,
            }
        }
        HostKeyFailureKind::Unknown { trust_allowed: false } => fixed_elsewhere(
            crate::i18n::gettext("Unknown SSH Host"),
            crate::i18n::gettext_f(
                "The SSH configuration for “{host}” accepts only keys already in known_hosts. Add the server’s key there, then retry.",
                &[("host", host)],
            ),
        ),
        // Without the file ssh named, there is no key to replace.
        HostKeyFailureKind::Changed { known_hosts, .. } if known_hosts.as_os_str().is_empty() => fixed_elsewhere(
            crate::i18n::gettext("SSH Host Key Changed"),
            crate::i18n::gettext_f(
                "The key “{host}” sent is not the one trusted in known_hosts. Someone may be intercepting the connection, or the server was reinstalled. If your server administrator confirms the new fingerprint, remove the old key from known_hosts, then retry.",
                &[("host", host)],
            ),
        ),
        HostKeyFailureKind::Changed { known_hosts, line } => HostKeyDialogSpec {
            heading: crate::i18n::gettext("SSH Host Key Changed"),
            body: crate::i18n::gettext_f(
                "The key “{host}” sent is not the one trusted in {file}, line {line}. Someone may be intercepting the connection, or the server was reinstalled. Replace the key only if your server administrator confirms the new fingerprint.",
                &[
                    ("host", host),
                    ("file", &known_hosts.display().to_string()),
                    ("line", &line.to_string()),
                ],
            ),
            responses: vec![
                HostKeyResponse::cancel(),
                HostKeyResponse::new(
                    REPLACE,
                    crate::i18n::gettext("Replace Key and Connect"),
                    adw::ResponseAppearance::Destructive,
                ),
            ],
            default: CANCEL,
            close: CANCEL,
        },
        HostKeyFailureKind::Revoked { detail } => fixed_elsewhere(
            crate::i18n::gettext("SSH Host Key Revoked"),
            crate::i18n::gettext_f(
                "The key “{host}” sent is revoked, so TablePro will not connect to it. Ask your server administrator for its current key. ssh reported: {detail}",
                &[("host", host), ("detail", detail)],
            ),
        ),
    }
}

/// Only a change outside TablePro clears these, so the dialog offers the
/// retry the banner would have.
fn fixed_elsewhere(heading: String, body: String) -> HostKeyDialogSpec {
    HostKeyDialogSpec {
        heading,
        body,
        responses: vec![HostKeyResponse::close(), HostKeyResponse::retry()],
        default: CLOSE,
        close: CLOSE,
    }
}

/// Show the key over `parent` and wait for the answer. Closing the
/// dialog any other way dismisses it.
pub(crate) async fn review_host_key(parent: &gtk::Widget, failure: &HostKeyFailure) -> HostKeyReviewOutcome {
    let dialog = build_dialog(failure);
    let response = crate::workspace::dialog_response::respond(&dialog, parent).await;
    match response.as_str() {
        TRUST => HostKeyReviewOutcome::Trust,
        REPLACE => HostKeyReviewOutcome::Replace,
        RETRY => HostKeyReviewOutcome::Retry,
        _ => HostKeyReviewOutcome::Dismissed,
    }
}

fn build_dialog(failure: &HostKeyFailure) -> adw::AlertDialog {
    let spec = host_key_dialog_spec(failure);
    let dialog = adw::AlertDialog::new(Some(&spec.heading), Some(&spec.body));
    for response in &spec.responses {
        dialog.add_response(response.id, &response.label);
        dialog.set_response_appearance(response.id, response.appearance);
    }
    dialog.set_default_response(Some(spec.default));
    dialog.set_close_response(spec.close);
    if !failure.fingerprint.is_empty() {
        dialog.set_extra_child(Some(&fingerprint_box(failure)));
    }
    dialog
}

/// Selectable, so the fingerprint can be copied and compared.
fn fingerprint_box(failure: &HostKeyFailure) -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let caption = match failure.algorithm.is_empty() {
        true => crate::i18n::gettext("Key fingerprint"),
        false => crate::i18n::gettext_f("{algorithm} key fingerprint", &[("algorithm", &failure.algorithm)]),
    };
    let caption = gtk::Label::new(Some(&caption));
    caption.add_css_class("dimmed");
    caption.add_css_class("caption");
    let fingerprint = gtk::Label::new(Some(&failure.fingerprint));
    fingerprint.add_css_class("monospace");
    fingerprint.set_selectable(true);
    fingerprint.set_wrap(true);
    fingerprint.set_wrap_mode(gtk::pango::WrapMode::Char);
    fingerprint.update_relation(&[gtk::accessible::Relation::LabelledBy(&[caption.upcast_ref()])]);
    column.append(&caption);
    column.append(&fingerprint);
    column
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::Duration;

    use gtk4::glib;

    use super::*;
    use crate::test_support::wait_until;
    use crate::workspace::dialog_response::visible_alert;

    fn failure(kind: HostKeyFailureKind, fingerprint: &str) -> HostKeyFailure {
        HostKeyFailure {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            fingerprint: fingerprint.to_owned(),
            kind,
        }
    }

    fn ids(spec: &HostKeyDialogSpec) -> Vec<&'static str> {
        spec.responses.iter().map(|response| response.id).collect()
    }

    #[test]
    fn host_key_dialog_spec_matrix() {
        let unknown = host_key_dialog_spec(&failure(
            HostKeyFailureKind::Unknown { trust_allowed: true },
            "SHA256:new",
        ));
        let unseen = host_key_dialog_spec(&failure(HostKeyFailureKind::Unknown { trust_allowed: true }, ""));
        let strict = host_key_dialog_spec(&failure(HostKeyFailureKind::Unknown { trust_allowed: false }, ""));
        let changed = host_key_dialog_spec(&failure(
            HostKeyFailureKind::Changed {
                known_hosts: PathBuf::from("/home/u/.ssh/known_hosts"),
                line: 3,
            },
            "SHA256:new",
        ));
        let revoked = host_key_dialog_spec(&failure(
            HostKeyFailureKind::Revoked {
                detail: "revoked by file /etc/ssh/krl".to_owned(),
            },
            "",
        ));
        let unplaced = host_key_dialog_spec(&failure(
            HostKeyFailureKind::Changed {
                known_hosts: PathBuf::new(),
                line: 0,
            },
            "SHA256:new",
        ));

        assert_eq!(ids(&unknown), [CANCEL, TRUST]);
        assert_eq!(ids(&unseen), [CANCEL, TRUST]);
        assert_eq!(unknown.responses[1].appearance, adw::ResponseAppearance::Suggested);
        assert_eq!(ids(&strict), [CLOSE, RETRY]);
        assert_eq!(ids(&changed), [CANCEL, REPLACE]);
        assert_eq!(changed.responses[1].appearance, adw::ResponseAppearance::Destructive);
        assert!(changed.body.contains("/home/u/.ssh/known_hosts"), "{}", changed.body);
        assert!(changed.body.contains('3'), "{}", changed.body);
        assert_eq!(ids(&revoked), [CLOSE, RETRY]);
        assert!(revoked.body.contains("/etc/ssh/krl"), "{}", revoked.body);
        assert_eq!(ids(&unplaced), [CLOSE, RETRY]);
        assert!(!unplaced.body.contains(", line 0"), "{}", unplaced.body);
        for spec in [&unknown, &unseen, &strict, &changed, &revoked, &unplaced] {
            assert!(spec.body.contains("bastion"), "{}", spec.body);
            assert_eq!(spec.default, spec.close, "{spec:?}");
            let default = spec.responses.iter().find(|response| response.id == spec.default);
            assert_eq!(
                default.map(|response| response.appearance),
                Some(adw::ResponseAppearance::Default),
                "{spec:?}"
            );
        }
    }

    #[gtk4::test]
    fn review_dialog_built_from_spec() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let failure = failure(HostKeyFailureKind::Unknown { trust_allowed: true }, "SHA256:new");
        let outcome = std::rc::Rc::new(std::cell::Cell::new(None));
        let sink = outcome.clone();
        let parent = window.clone().upcast::<gtk::Widget>();
        glib::spawn_future_local(async move {
            sink.set(Some(review_host_key(&parent, &failure).await));
        });
        wait_until(Duration::from_secs(10), || visible_alert(&window).is_some()).expect("the dialog");

        let dialog = visible_alert(&window).unwrap();
        let fingerprint = crate::test_support::descendants(&dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .find(|label| label.label() == "SHA256:new")
            .expect("the fingerprint label");
        assert!(fingerprint.is_selectable());
        assert!(fingerprint.has_css_class("monospace"));
        dialog.force_close();

        wait_until(Duration::from_secs(10), || outcome.get().is_some()).expect("an outcome");
        assert_eq!(outcome.get(), Some(HostKeyReviewOutcome::Dismissed));
    }
}
