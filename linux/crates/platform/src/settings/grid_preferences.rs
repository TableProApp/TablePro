use std::cell::{OnceCell, RefCell};
use std::rc::Rc;
use std::sync::OnceLock;

use gio::prelude::*;
use glib::subclass::prelude::*;

use super::{EditorFont, keys};

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum GridRowHeight {
    Compact,
    #[default]
    Normal,
    Comfortable,
    Spacious,
}

impl GridRowHeight {
    pub const ALL: [Self; 4] = [Self::Compact, Self::Normal, Self::Comfortable, Self::Spacious];

    pub fn from_nick(nick: &str) -> Self {
        match nick {
            "compact" => Self::Compact,
            "comfortable" => Self::Comfortable,
            "spacious" => Self::Spacious,
            _ => Self::Normal,
        }
    }

    pub fn nick(self) -> &'static str {
        match self {
            Self::Compact => "compact",
            Self::Normal => "normal",
            Self::Comfortable => "comfortable",
            Self::Spacious => "spacious",
        }
    }

    pub fn css_class(self) -> &'static str {
        match self {
            Self::Compact => "row-compact",
            Self::Normal => "row-normal",
            Self::Comfortable => "row-comfortable",
            Self::Spacious => "row-spacious",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GridPreferenceValues {
    pub show_row_numbers: bool,
    pub show_alternate_rows: bool,
    pub row_height: GridRowHeight,
    pub null_display: String,
    pub font: EditorFont,
}

impl Default for GridPreferenceValues {
    fn default() -> Self {
        Self {
            show_row_numbers: true,
            show_alternate_rows: true,
            row_height: GridRowHeight::Normal,
            null_display: "NULL".to_owned(),
            font: EditorFont::System,
        }
    }
}

impl GridPreferenceValues {
    fn read(settings: &gio::Settings) -> Self {
        Self {
            show_row_numbers: settings.boolean(keys::SHOW_ROW_NUMBERS),
            show_alternate_rows: settings.boolean(keys::SHOW_ALTERNATE_ROWS),
            row_height: GridRowHeight::from_nick(&settings.string(keys::GRID_ROW_HEIGHT)),
            null_display: null_display_text(&settings.string(keys::NULL_DISPLAY)),
            font: if settings.boolean(keys::GRID_USE_SYSTEM_FONT) {
                EditorFont::System
            } else {
                EditorFont::Custom(settings.string(keys::GRID_FONT).into())
            },
        }
    }
}

fn null_display_text(text: &str) -> String {
    let text: String = text.chars().filter(|ch| !ch.is_control()).take(20).collect();
    if text.trim().is_empty() {
        "NULL".to_owned()
    } else {
        text
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GridPreferences {
        pub(super) settings: OnceCell<gio::Settings>,
        pub(super) handler: RefCell<Option<glib::SignalHandlerId>>,
        pub(super) values: RefCell<Rc<GridPreferenceValues>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridPreferences {
        const NAME: &'static str = "TableProGridPreferences";
        type Type = super::GridPreferences;
    }

    impl ObjectImpl for GridPreferences {
        fn signals() -> &'static [glib::subclass::Signal] {
            static SIGNALS: OnceLock<Vec<glib::subclass::Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![glib::subclass::Signal::builder("changed").build()])
        }

        fn dispose(&self) {
            if let (Some(settings), Some(handler)) = (self.settings.get(), self.handler.take()) {
                settings.disconnect(handler);
            }
        }
    }
}

glib::wrapper! {
    pub struct GridPreferences(ObjectSubclass<imp::GridPreferences>);
}

impl Default for GridPreferences {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl GridPreferences {
    pub(super) fn new(settings: &gio::Settings) -> Self {
        let preferences = Self::default();
        let _ = preferences.imp().settings.set(settings.clone());
        let weak = preferences.downgrade();
        // GSettings only announces keys read after a handler was connected.
        let handler = settings.connect_changed(None, move |settings, key| {
            if matches!(
                key,
                keys::SHOW_ROW_NUMBERS
                    | keys::SHOW_ALTERNATE_ROWS
                    | keys::GRID_ROW_HEIGHT
                    | keys::NULL_DISPLAY
                    | keys::GRID_USE_SYSTEM_FONT
                    | keys::GRID_FONT
            ) && let Some(preferences) = weak.upgrade()
            {
                preferences.update(GridPreferenceValues::read(settings));
            }
        });
        preferences.imp().handler.replace(Some(handler));
        preferences.update(GridPreferenceValues::read(settings));
        preferences
    }

    pub fn snapshot(&self) -> Rc<GridPreferenceValues> {
        self.imp().values.borrow().clone()
    }

    pub fn connect_changed(&self, callback: impl Fn(&Self) + 'static) -> glib::SignalHandlerId {
        self.connect_closure(
            "changed",
            false,
            glib::closure_local!(move |preferences: Self| callback(&preferences)),
        )
    }

    fn update(&self, values: GridPreferenceValues) {
        if *self.imp().values.borrow().as_ref() == values {
            return;
        }
        self.imp().values.replace(Rc::new(values));
        self.emit_by_name::<()>("changed", &[]);
    }
}
