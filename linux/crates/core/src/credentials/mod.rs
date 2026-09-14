mod credential_interaction;
mod credential_prompt;
mod credential_prompter;
mod prompt_field;
mod prompt_purpose;
mod prompt_reason;
mod prompt_reply;

pub use credential_interaction::CredentialInteraction;
pub use credential_prompt::CredentialPrompt;
pub use credential_prompter::CredentialPrompter;
pub use prompt_field::PromptField;
pub use prompt_purpose::PromptPurpose;
pub use prompt_reason::PromptReason;
pub use prompt_reply::PromptReply;

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use futures::future::BoxFuture;
    use secrecy::{ExposeSecret, SecretString};

    use super::*;

    struct AnsweringPrompter;

    impl CredentialPrompter for AnsweringPrompter {
        fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
            let values = request
                .fields
                .iter()
                .map(|field| SecretString::from(format!("answer for {}", field.label)))
                .collect();
            Box::pin(async move {
                PromptReply::Submitted {
                    values,
                    remember: request.offer_remember,
                }
            })
        }
    }

    fn assert_send_sync<T: Send + Sync + ?Sized>() {}

    #[test]
    fn prompter_trait_object_is_send_sync() {
        assert_send_sync::<dyn CredentialPrompter>();
        assert_send_sync::<CredentialInteraction>();
    }

    #[tokio::test]
    async fn attended_interaction_prompts_through_its_prompter() {
        let interaction = CredentialInteraction::Attended(Arc::new(AnsweringPrompter));
        let CredentialInteraction::Attended(prompter) = interaction.clone() else {
            panic!("expected an attended interaction");
        };
        let request = CredentialPrompt {
            purpose: PromptPurpose::DatabasePassword {
                reason: PromptReason::NotStored,
            },
            target: "deploy@db.example.com".to_owned(),
            fields: vec![PromptField {
                label: "Password".to_owned(),
                secret: true,
            }],
            offer_remember: true,
        };

        let PromptReply::Submitted { values, remember } = prompter.prompt(request).await else {
            panic!("expected a submitted reply");
        };
        assert!(remember);
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].expose_secret(), "answer for Password");
        assert_eq!(format!("{interaction:?}"), "Attended");
    }
}
