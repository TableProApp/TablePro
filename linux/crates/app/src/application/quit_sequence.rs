use futures::channel::oneshot;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::TableProApplication;
use super::imp::RestoreState;
use crate::runtime::{DeliverInput, Delivery};
use crate::ui::SessionWindowInput;
use crate::workspace::{CloseDecision, CloseReason};

/// Asks each window in turn whether it may close, the way closing it by
/// hand would.
///
/// It never calls `g_application_quit`, which ignores the hold count:
/// the process ends once the last window is gone and the last save,
/// close and teardown hold has dropped.
///
/// The open sessions stay recorded through the quit, so the next launch
/// reopens the windows it closes. The record is written before the
/// process may end, and a cancelled quit keeps only the windows still
/// showing or connecting their session.
///
/// An approved quit can leave the process running with no window while
/// a session closes, and a second launch then activates it. That
/// activate restores the record as a new process would, after the
/// record is written if it lands while the quit writes it.
pub struct QuitSequence;

impl QuitSequence {
    pub async fn run(app: TableProApplication) -> CloseDecision {
        let services = app.services();
        // Taken before the first window closes: the last one going would
        // end the process before the record is written.
        let hold = services.as_ref().map(|services| services.hold().acquire());
        if let Some(services) = &services {
            services.open_sessions().freeze_for_quit();
        }
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
        if let Some(services) = &services {
            match decision {
                CloseDecision::Approved => {
                    let restore = &app.imp().restore;
                    let restorable = restore.get() == RestoreState::Done;
                    if restorable {
                        restore.set(RestoreState::Quitting { relaunched: false });
                    }
                    services.open_sessions().flush().await;
                    services.open_sessions().end_quit();
                    if restorable {
                        let relaunched = restore.get() == RestoreState::Quitting { relaunched: true };
                        restore.set(RestoreState::NotAttempted);
                        if relaunched {
                            app.restore_session();
                        }
                    }
                }
                CloseDecision::Cancelled => services.open_sessions().thaw(|key| {
                    services
                        .sessions
                        .window_for(key)
                        .is_some_and(|window_id| app.imp().windows.keeps_session(window_id))
                }),
            }
        }
        drop(hold);
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
