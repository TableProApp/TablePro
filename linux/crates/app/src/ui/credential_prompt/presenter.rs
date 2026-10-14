use std::pin::pin;

use adw::prelude::*;
use futures::future::{Either, select};
use libadwaita as adw;
use tablepro_core::credentials::PromptReply;
use tokio::sync::oneshot;

use super::prompt_form::PromptForm;
use super::prompter::{PendingPrompt, PromptQueue};

/// Shows queued credential prompts over a window, one at a time.
///
/// Sequential on purpose: two connects asking at once would otherwise
/// stack two password dialogs with nothing saying which is which.
#[derive(Debug)]
pub struct CredentialPromptPresenter;

impl CredentialPromptPresenter {
    /// Drain `queue` over `parent` until the returned handle is aborted
    /// or the window goes. Aborting drops the queue, which cancels the
    /// prompt being shown and every one still waiting.
    pub fn start(mut queue: PromptQueue, parent: &impl IsA<gtk4::Widget>) -> glib::JoinHandle<()> {
        let parent = parent.upcast_ref::<gtk4::Widget>().downgrade();
        glib::spawn_future_local(async move {
            while let Some(pending) = queue.next().await {
                let PendingPrompt { prompt, mut reply } = pending;
                if reply.is_closed() {
                    continue;
                }
                let answer = match parent.upgrade() {
                    Some(parent) => {
                        let form = PromptForm::build(&prompt);
                        let Some(response) = response_while_wanted(&form.dialog, &parent, &mut reply).await else {
                            // The connect that asked was cancelled. Its
                            // dialog goes with it, or the next prompt
                            // would wait behind one nobody can answer.
                            form.abandon();
                            continue;
                        };
                        form.reply(&response)
                    }
                    None => PromptReply::Cancelled,
                };
                // The asker can still go between the response and here;
                // nobody is waiting then, which is fine.
                let _ = reply.send(answer);
            }
        })
    }
}

async fn response_while_wanted(
    dialog: &adw::AlertDialog,
    parent: &gtk4::Widget,
    reply: &mut oneshot::Sender<PromptReply>,
) -> Option<String> {
    match select(pin!(crate::workspace::respond(dialog, parent)), pin!(reply.closed())).await {
        Either::Left((response, _)) => Some(response),
        Either::Right(((), _)) => None,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptField, PromptPurpose, PromptReason};

    use super::*;
    use crate::ui::credential_prompt::GtkCredentialPrompter;

    fn prompt(target: &str) -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::DatabasePassword {
                reason: PromptReason::NotStored,
            },
            target: target.to_owned(),
            fields: vec![PromptField {
                label: "Password".to_owned(),
                secret: true,
            }],
            offer_remember: true,
        }
    }

    fn open_alerts(window: &adw::Window) -> Vec<adw::AlertDialog> {
        window
            .dialogs()
            .iter::<glib::Object>()
            .filter_map(|item| item.ok()?.downcast::<adw::AlertDialog>().ok())
            .collect()
    }

    #[gtk4::test]
    fn prompts_are_presented_sequentially() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let (prompter, queue) = GtkCredentialPrompter::new();
        let presenter = CredentialPromptPresenter::start(queue, &window);
        let answered = std::rc::Rc::new(std::cell::Cell::new(0));
        for target in ["first", "second"] {
            let asking = prompter.prompt(prompt(target));
            let answered = answered.clone();
            glib::spawn_future_local(async move {
                asking.await;
                answered.set(answered.get() + 1);
            });
        }

        crate::test_support::wait_until(Duration::from_secs(5), || open_alerts(&window).len() == 1)
            .expect("the first prompt");
        crate::test_support::drain_main_context();
        let shown = open_alerts(&window);
        assert_eq!(shown.len(), 1, "the second prompt did not wait for the first");
        assert!(shown[0].body().contains("first"));
        shown[0].close();

        crate::test_support::wait_until(Duration::from_secs(5), || {
            open_alerts(&window).iter().any(|alert| alert.body().contains("second"))
        })
        .expect("the second prompt after the first closed");
        for alert in open_alerts(&window) {
            alert.close();
        }
        crate::test_support::wait_until(Duration::from_secs(5), || answered.get() == 2).expect("both prompts answered");
        presenter.abort();
        window.close();
        crate::test_support::drain_main_context();
    }

    #[gtk4::test]
    fn a_prompt_whose_connect_was_cancelled_closes_and_lets_the_next_one_show() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let (prompter, queue) = GtkCredentialPrompter::new();
        let presenter = CredentialPromptPresenter::start(queue, &window);
        let cancelled = prompter.prompt(prompt("cancelled"));
        crate::test_support::wait_until(Duration::from_secs(5), || open_alerts(&window).len() == 1)
            .expect("the first prompt");

        drop(cancelled);

        crate::test_support::wait_until(Duration::from_secs(5), || open_alerts(&window).is_empty())
            .expect("the dialog of a cancelled connect stayed on screen");
        let answered = std::rc::Rc::new(std::cell::Cell::new(false));
        let asking = prompter.prompt(prompt("next"));
        let sink = answered.clone();
        glib::spawn_future_local(async move {
            asking.await;
            sink.set(true);
        });
        crate::test_support::wait_until(Duration::from_secs(5), || {
            open_alerts(&window).iter().any(|alert| alert.body().contains("next"))
        })
        .expect("the next prompt behind the cancelled one");
        for alert in open_alerts(&window) {
            alert.close();
        }
        crate::test_support::wait_until(Duration::from_secs(5), || answered.get()).expect("the next prompt answered");
        presenter.abort();
        window.close();
        crate::test_support::drain_main_context();
    }

    #[gtk4::test]
    fn connect_hands_over_the_typed_password_with_animations_on_or_off() {
        use secrecy::ExposeSecret;

        adw::init().expect("libadwaita initialises under the test backend");
        let settings = gtk4::Settings::default().expect("the default settings");
        let animations = settings.is_gtk_enable_animations();
        for enabled in [true, false] {
            settings.set_gtk_enable_animations(enabled);
            let window = adw::Window::new();
            window.present();
            let (prompter, queue) = GtkCredentialPrompter::new();
            let presenter = CredentialPromptPresenter::start(queue, &window);
            let reply = std::rc::Rc::new(std::cell::RefCell::new(None));
            let asking = prompter.prompt(prompt("accepted"));
            let sink = reply.clone();
            glib::spawn_future_local(async move {
                *sink.borrow_mut() = Some(asking.await);
            });
            crate::test_support::wait_until(Duration::from_secs(5), || open_alerts(&window).len() == 1)
                .expect("the prompt");
            let rows = open_alerts(&window)[0].extra_child().expect("the prompt's rows");
            crate::test_support::descendants(&rows)
                .into_iter()
                .find_map(|widget| widget.downcast::<adw::PasswordEntryRow>().ok())
                .expect("the password row")
                .set_text("hunter2");

            assert!(crate::workspace::answer(&window, super::super::prompt_form::ACCEPT));

            crate::test_support::wait_until(Duration::from_secs(5), || reply.borrow().is_some()).expect("an answer");
            let answered = reply.borrow_mut().take();
            let Some(PromptReply::Submitted { values, .. }) = answered else {
                panic!("Connect answered {answered:?} with animations {enabled}");
            };
            assert_eq!(values[0].expose_secret(), "hunter2");
            presenter.abort();
            window.close();
            crate::test_support::drain_main_context();
        }
        settings.set_gtk_enable_animations(animations);
    }

    #[gtk4::test]
    fn a_prompt_whose_dialog_is_forced_shut_is_cancelled() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let (prompter, queue) = GtkCredentialPrompter::new();
        let presenter = CredentialPromptPresenter::start(queue, &window);
        let reply = std::rc::Rc::new(std::cell::RefCell::new(None));
        let asking = prompter.prompt(prompt("forced"));
        let sink = reply.clone();
        glib::spawn_future_local(async move {
            *sink.borrow_mut() = Some(asking.await);
        });

        crate::test_support::wait_until(Duration::from_secs(5), || open_alerts(&window).len() == 1)
            .expect("the prompt");
        for alert in open_alerts(&window) {
            alert.force_close();
        }
        crate::test_support::wait_until(Duration::from_secs(5), || reply.borrow().is_some()).expect("an answer");

        assert!(matches!(reply.borrow_mut().take(), Some(PromptReply::Cancelled)));
        presenter.abort();
        window.close();
        crate::test_support::drain_main_context();
    }
}
