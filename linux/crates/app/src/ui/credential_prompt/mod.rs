//! Asking the user for what the keyring or the SSH configuration could
//! not supply: a password, a key passphrase, a server's own questions,
//! or whether to trust a host key seen for the first time.
//!
//! The prompter is called from connect work on the runtime; the dialogs
//! live on the GTK thread. A queue joins the two, and the presenter
//! shows one prompt at a time so two connects never stack dialogs.

mod presenter;
mod prompt_form;
mod prompt_text;
mod prompter;

pub use presenter::CredentialPromptPresenter;
pub use prompter::{GtkCredentialPrompter, PromptQueue};
