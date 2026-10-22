use std::fmt;
use std::ops::Deref;

use relm4::gtk;

use super::error_navigation::ErrorTarget;

#[derive(Clone, Debug)]
pub struct StatementFailure {
    message: String,
    pub(super) position: Option<usize>,
    pub(super) target: Option<ErrorTarget>,
}

impl StatementFailure {
    pub(super) fn located(error: &tablepro_core::DriverError, written: &str, sent: &str) -> Self {
        let position = match error {
            tablepro_core::DriverError::Query { position, .. } if sent == written => {
                position.filter(|position| super::error_location::line_and_column(written, *position).is_some())
            }
            _ => None,
        };
        let message = crate::services::error_text::driver_message(error);
        Self {
            message: super::error_location::located_message(&message, written, position),
            position,
            target: None,
        }
    }

    pub(super) fn navigation_button(&self) -> Option<gtk::Button> {
        let target = self.target?;
        Some(
            gtk::Button::builder()
                .label(crate::tr!("Go to error"))
                .action_name("editor-error.jump")
                .action_target(&target.variant())
                .halign(gtk::Align::Center)
                .build(),
        )
    }
}

impl From<String> for StatementFailure {
    fn from(message: String) -> Self {
        Self {
            message,
            position: None,
            target: None,
        }
    }
}

impl From<&str> for StatementFailure {
    fn from(message: &str) -> Self {
        message.to_string().into()
    }
}

impl Deref for StatementFailure {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        &self.message
    }
}

impl fmt::Display for StatementFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(formatter)
    }
}

impl AsRef<str> for StatementFailure {
    fn as_ref(&self) -> &str {
        &self.message
    }
}
