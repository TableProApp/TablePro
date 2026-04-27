use relm4::adw::prelude::*;
use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::{adw, gtk};
use uuid::Uuid;

use tablepro_storage::SavedConnection;

#[derive(Debug)]
pub struct ConnectionRow {
    saved: SavedConnection,
}

#[derive(Debug)]
pub enum ConnectionRowMsg {
    Open,
    Delete,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum ConnectionRowOutput {
    Open(SavedConnection),
    Delete(Uuid),
}

#[relm4::factory(pub)]
impl FactoryComponent for ConnectionRow {
    type Init = SavedConnection;
    type Input = ConnectionRowMsg;
    type Output = ConnectionRowOutput;
    type CommandOutput = ();
    type ParentWidget = gtk::ListBox;

    view! {
        adw::ActionRow {
            set_title: &self.saved.name,
            set_subtitle: &subtitle_for(&self.saved),
            set_activatable: true,
            connect_activated => ConnectionRowMsg::Open,

            add_suffix = &gtk::Button {
                set_icon_name: "user-trash-symbolic",
                set_valign: gtk::Align::Center,
                set_tooltip_text: Some(crate::tr!("Remove connection").as_str()),
                add_css_class: "flat",
                add_css_class: "destructive-action",
                connect_clicked => ConnectionRowMsg::Delete,
            },
        }
    }

    fn init_model(saved: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        Self { saved }
    }

    fn update(&mut self, msg: Self::Input, sender: FactorySender<Self>) {
        match msg {
            ConnectionRowMsg::Open => {
                let _ = sender.output(ConnectionRowOutput::Open(self.saved.clone()));
            }
            ConnectionRowMsg::Delete => {
                let _ = sender.output(ConnectionRowOutput::Delete(self.saved.id));
            }
        }
    }
}

fn subtitle_for(saved: &SavedConnection) -> String {
    if saved.driver_id == "sqlite" {
        format!("sqlite · {}", saved.database)
    } else {
        format!("{} · {}@{}:{}", saved.driver_id, saved.username, saved.host, saved.port)
    }
}
