use futures::channel::oneshot;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::TableProApplication;
use crate::runtime::{DeliverInput, Delivery};
use crate::ui::SessionWindowInput;
use crate::workspace::{CloseDecision, CloseReason};

/// Asks each window in turn whether it may close, the way closing it by
/// hand would.
///
/// It never calls `g_application_quit`, which ignores the hold count:
/// the process ends once the last window is gone and the last save,
/// close and teardown hold has dropped.
pub struct QuitSequence;

impl QuitSequence {
    pub async fn run(app: TableProApplication) -> CloseDecision {
        let mut asked: Vec<gtk::Window> = Vec::new();
        let decision = loop {
            let Some(window) = app.windows().into_iter().find(|window| !asked.contains(window)) else {
                break CloseDecision::Approved;
            };
            asked.push(window.clone());
            if ask(&app, &window).await == CloseDecision::Cancelled {
                break CloseDecision::Cancelled;
            }
        };
        app.imp().quit_asking.set(None);
        decision
    }
}

async fn ask(app: &TableProApplication, window: &gtk::Window) -> CloseDecision {
    let sender = window
        .downcast_ref::<gtk::ApplicationWindow>()
        .and_then(|window| app.imp().windows.sender(window.id()));
    let Some(sender) = sender else {
        // Not one of the session windows, so it has nothing to ask.
        window.close();
        return CloseDecision::Approved;
    };
    if let Some(window) = window.downcast_ref::<gtk::ApplicationWindow>() {
        app.imp().quit_asking.set(Some(window.id()));
    }
    window.present();
    let (reply, answer) = oneshot::channel();
    if sender.try_deliver(SessionWindowInput::CloseRequested(CloseReason::Quit(reply))) == Delivery::ReceiverGone {
        return CloseDecision::Approved;
    }
    // A window torn down before it answered has nothing left to keep.
    answer.await.unwrap_or(CloseDecision::Approved)
}
