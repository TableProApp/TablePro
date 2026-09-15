use std::any::Any;

/// What a panicking task said, recovered from the boxed payload.
///
/// `Box<dyn Any>` is not `Debug` or `Display`, so the message is pulled
/// out here and the payload dropped. Without this the failure reaches
/// the UI as an opaque type name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskPanic {
    message: String,
}

impl TaskPanic {
    pub fn from_payload(payload: Box<dyn Any + Send>) -> Self {
        Self {
            message: message_of(payload.as_ref()),
        }
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

fn message_of(payload: &(dyn Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&'static str>() {
        return (*text).to_owned();
    }
    if let Some(text) = payload.downcast_ref::<String>() {
        return text.clone();
    }
    // `panic_any` with some other type: there is nothing to read, but
    // the failure still has to be reportable.
    "a background task panicked".to_owned()
}

impl std::fmt::Display for TaskPanic {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_str_payload() {
        let panic = TaskPanic::from_payload(Box::new("boom"));

        assert_eq!(panic.message(), "boom");
    }

    #[test]
    fn from_string_payload() {
        let panic = TaskPanic::from_payload(Box::new("boom 2".to_owned()));

        assert_eq!(panic.message(), "boom 2");
    }

    #[test]
    fn from_other_payload_placeholder() {
        let panic = TaskPanic::from_payload(Box::new(42_u32));

        assert_eq!(panic.message(), "a background task panicked");
    }
}
