use adw::prelude::*;
use libadwaita as adw;
use secrecy::SecretString;
use tablepro_core::credentials::{CredentialPrompt, PromptField, PromptReply};

use super::prompt_text::PromptText;

pub(super) const CANCEL: &str = "cancel";
pub(super) const ACCEPT: &str = "accept";

/// One answer the prompt asks for. A secret field never shows what is
/// typed; an echo field is a server question whose answer is not secret.
#[derive(Debug, Clone)]
pub(super) enum FieldRow {
    Secret(adw::PasswordEntryRow),
    Echo(adw::EntryRow),
}

impl FieldRow {
    fn build(field: &PromptField) -> Self {
        let title = field_title(&field.label);
        if field.secret {
            Self::Secret(
                adw::PasswordEntryRow::builder()
                    .title(title)
                    .activates_default(true)
                    .build(),
            )
        } else {
            Self::Echo(adw::EntryRow::builder().title(title).activates_default(true).build())
        }
    }

    fn widget(&self) -> &gtk4::Widget {
        match self {
            Self::Secret(row) => row.upcast_ref(),
            Self::Echo(row) => row.upcast_ref(),
        }
    }

    /// Hand the typed text over and clear the row, so the answer lives
    /// in a zeroizing secret and nowhere in the widget tree.
    fn take(&self) -> SecretString {
        let editable: &gtk4::Editable = match self {
            Self::Secret(row) => row.upcast_ref(),
            Self::Echo(row) => row.upcast_ref(),
        };
        let secret = SecretString::from(editable.text().as_str().to_owned());
        editable.set_text("");
        secret
    }
}

/// The dialog for one prompt, with the rows its answer is read from.
#[derive(Debug, Clone)]
pub(super) struct PromptForm {
    pub dialog: adw::AlertDialog,
    pub rows: Vec<FieldRow>,
    pub remember: Option<adw::SwitchRow>,
}

impl PromptForm {
    pub fn build(prompt: &CredentialPrompt) -> Self {
        let text = PromptText::for_prompt(prompt);
        let dialog = adw::AlertDialog::new(Some(&text.heading), Some(&text.body));
        dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
        dialog.add_response(ACCEPT, &text.accept);
        dialog.set_response_appearance(ACCEPT, adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some(ACCEPT));
        dialog.set_close_response(CANCEL);

        let rows: Vec<FieldRow> = prompt.fields.iter().map(FieldRow::build).collect();
        let remember = prompt.offer_remember.then(|| {
            adw::SwitchRow::builder()
                .title(text.remember.as_str())
                .active(false)
                .build()
        });
        if !rows.is_empty() || remember.is_some() {
            let group = adw::PreferencesGroup::new();
            for row in &rows {
                group.add(row.widget());
            }
            if let Some(remember) = &remember {
                group.add(remember);
            }
            dialog.set_extra_child(Some(&group));
        }
        Self { dialog, rows, remember }
    }

    pub fn abandon(&self) {
        for row in &self.rows {
            drop(row.take());
        }
        self.dialog.force_close();
    }

    /// The reply for the response the dialog closed with. Anything but
    /// the accept button, including Escape, is a cancel.
    pub fn reply(&self, response: &str) -> PromptReply {
        let values: Vec<SecretString> = self.rows.iter().map(FieldRow::take).collect();
        if response != ACCEPT {
            return PromptReply::Cancelled;
        }
        PromptReply::Submitted {
            values,
            remember: self.remember.as_ref().is_some_and(adw::SwitchRow::is_active),
        }
    }
}

/// The storage and SSH crates name their fields in English; the two
/// they use are translated here, and a server's own question is shown
/// as the server wrote it.
fn field_title(label: &str) -> String {
    match label {
        "Password" => crate::i18n::gettext("Password"),
        "Passphrase" => crate::i18n::gettext("Passphrase"),
        other => other.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;
    use tablepro_core::credentials::{PromptPurpose, PromptReason};

    use super::*;

    fn password_prompt(offer_remember: bool) -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::DatabasePassword {
                reason: PromptReason::NotStored,
            },
            target: "app@db.example.com:5432/shop".to_owned(),
            fields: vec![PromptField {
                label: "Password".to_owned(),
                secret: true,
            }],
            offer_remember,
        }
    }

    #[gtk4::test]
    fn presenter_builds_rows_per_field_and_remember_switch() {
        adw::init().expect("libadwaita initialises under the test backend");

        let form = PromptForm::build(&password_prompt(true));

        assert_eq!(form.rows.len(), 1);
        assert!(matches!(form.rows[0], FieldRow::Secret(_)));
        assert!(form.remember.is_some(), "a remember switch was not offered");
        assert!(form.dialog.extra_child().is_some());
        assert_eq!(form.dialog.default_response().as_deref(), Some(ACCEPT));

        let without = PromptForm::build(&password_prompt(false));
        assert!(without.remember.is_none(), "remember was offered where it cannot work");
    }

    #[gtk4::test]
    fn keyboard_interactive_echo_field_is_entry_row() {
        adw::init().expect("libadwaita initialises under the test backend");
        let prompt = CredentialPrompt {
            purpose: PromptPurpose::SshKeyboardInteractive {
                name: String::new(),
                instructions: String::new(),
            },
            target: "bastion".to_owned(),
            fields: vec![
                PromptField {
                    label: "Username:".to_owned(),
                    secret: false,
                },
                PromptField {
                    label: "Verification code:".to_owned(),
                    secret: true,
                },
            ],
            offer_remember: false,
        };

        let form = PromptForm::build(&prompt);

        assert!(matches!(form.rows[0], FieldRow::Echo(_)));
        assert!(matches!(form.rows[1], FieldRow::Secret(_)));
    }

    #[gtk4::test]
    fn accepting_hands_over_the_typed_secret_and_clears_the_row() {
        adw::init().expect("libadwaita initialises under the test backend");
        let form = PromptForm::build(&password_prompt(true));
        let FieldRow::Secret(row) = &form.rows[0] else {
            panic!("expected a secret row");
        };
        row.set_text("hunter2");
        if let Some(remember) = &form.remember {
            remember.set_active(true);
        }

        let PromptReply::Submitted { values, remember } = form.reply(ACCEPT) else {
            panic!("expected a submitted reply");
        };

        assert_eq!(values[0].expose_secret(), "hunter2");
        assert!(remember);
        assert_eq!(row.text(), "", "the secret stayed in the widget");
    }

    #[gtk4::test]
    fn closing_dialog_replies_cancelled() {
        adw::init().expect("libadwaita initialises under the test backend");
        let form = PromptForm::build(&password_prompt(true));
        let FieldRow::Secret(row) = &form.rows[0] else {
            panic!("expected a secret row");
        };
        row.set_text("hunter2");

        assert!(matches!(form.reply(CANCEL), PromptReply::Cancelled));
        assert_eq!(row.text(), "", "a cancelled secret stayed in the widget");
    }

    #[gtk4::test]
    fn a_host_key_prompt_has_no_rows_and_accepts_with_no_values() {
        adw::init().expect("libadwaita initialises under the test backend");
        let prompt = CredentialPrompt {
            purpose: PromptPurpose::SshHostKeyConfirmation {
                host: "bastion.example.com".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: "SHA256:abc".to_owned(),
            },
            target: "bastion.example.com".to_owned(),
            fields: Vec::new(),
            offer_remember: false,
        };

        let form = PromptForm::build(&prompt);

        assert!(form.dialog.extra_child().is_none());
        let PromptReply::Submitted { values, remember } = form.reply(ACCEPT) else {
            panic!("expected a submitted reply");
        };
        assert!(values.is_empty());
        assert!(!remember);
    }
}
