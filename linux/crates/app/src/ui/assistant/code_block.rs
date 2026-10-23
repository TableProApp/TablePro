use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use sourceview5::prelude::*;

use crate::ui::handler_guard::HandlerGuard;

/// What a code block's buttons reach beyond it.
#[derive(Clone)]
pub(crate) struct BlockHooks {
    pub settings: Rc<tablepro_storage::AppSettings>,
    /// Put the code in the editor.
    pub insert: Rc<dyn Fn(String)>,
    pub toast: Rc<dyn Fn(String)>,
}

/// One code block of a reply: highlighted as the editor is, with Copy
/// and Insert. A label rather than a text view: a text view lays its
/// text out in an idle that a running spinner can hold off, and until
/// then asks for the height of no text.
pub(crate) struct CodeBlock {
    root: gtk::Box,
    shown: Rc<Shown>,
    settings: Rc<tablepro_storage::AppSettings>,
    _theme: [HandlerGuard; 2],
}

/// The code and the label that shows it, with the buffer that colours it.
struct Shown {
    code: RefCell<String>,
    label: gtk::Label,
    buffer: sourceview5::Buffer,
}

impl CodeBlock {
    pub(crate) fn new(code: &str, language: Option<&str>, hooks: &BlockHooks) -> Self {
        let sql = language.is_none_or(|language| matches!(language, "sql" | "mysql" | "postgresql" | "sqlite"));
        let buffer = match sql
            .then(|| sourceview5::LanguageManager::default().language("sql"))
            .flatten()
        {
            Some(sql) => sourceview5::Buffer::with_language(&sql),
            None => sourceview5::Buffer::new(None),
        };
        let label = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .selectable(true)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(10)
            .margin_end(10)
            .build();
        label.add_css_class("monospace");
        let shown = Rc::new(Shown {
            code: RefCell::new(code.to_owned()),
            label,
            buffer,
        });
        shown.paint(&hooks.settings.style_scheme());

        let style_manager = adw::StyleManager::default();
        let settings = Rc::downgrade(&hooks.settings);
        let themed = Rc::downgrade(&shown);
        let theme = style_manager.connect_dark_notify(move |_| {
            if let (Some(shown), Some(settings)) = (themed.upgrade(), settings.upgrade()) {
                shown.paint(&settings.style_scheme());
            }
        });
        let themed = Rc::downgrade(&shown);
        let scheme = hooks.settings.gio().connect_changed(
            Some(tablepro_storage::settings::keys::STYLE_SCHEME),
            move |settings, key| {
                if let Some(shown) = themed.upgrade() {
                    shown.paint(&settings.string(key));
                }
            },
        );

        let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        header.set_margin_start(10);
        header.set_margin_end(4);
        header.set_margin_top(4);
        let name = gtk::Label::builder()
            .label(language.unwrap_or_default().to_uppercase())
            .xalign(0.0)
            .hexpand(true)
            .build();
        name.add_css_class("caption");
        name.add_css_class("dim-label");
        header.append(&name);
        header.append(&copy_button(&shown, hooks));
        header.append(&insert_button(&shown, hooks));

        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("card");
        root.set_overflow(gtk::Overflow::Hidden);
        root.append(&header);
        root.append(&shown.label);
        Self {
            root,
            shown,
            settings: hooks.settings.clone(),
            _theme: [
                HandlerGuard::new(&style_manager, theme),
                HandlerGuard::new(hooks.settings.gio(), scheme),
            ],
        }
    }

    pub(crate) fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// Show `code` in place of what the block shows, as a reply streams.
    pub(crate) fn set_code(&self, code: &str) {
        if *self.shown.code.borrow() == code {
            return;
        }
        self.shown.code.replace(code.to_owned());
        self.shown.paint(&self.settings.style_scheme());
    }
}

impl Shown {
    /// Lay the code out in the label, coloured by the `scheme` the user
    /// picked for the editor.
    fn paint(&self, scheme: &str) {
        let code = self.code.borrow();
        self.buffer
            .set_style_scheme(crate::ui::style_scheme_resolver::scheme(scheme).as_ref());
        self.buffer.set_text(&code);
        let (start, end) = self.buffer.bounds();
        self.buffer.ensure_highlight(&start, &end);
        let colours = gtk::pango::AttrList::new();
        let mut at = start;
        let mut byte: u32 = 0;
        while at.offset() < end.offset() {
            let mut next = at;
            if !next.forward_to_tag_toggle(None::<&gtk::TextTag>) {
                next = end;
            }
            let length = u32::try_from(self.buffer.text(&at, &next, true).len()).unwrap_or(u32::MAX);
            let range = (byte, byte.saturating_add(length));
            // Tags come lowest priority first, so the last one set wins.
            for tag in at.tags() {
                for mut attribute in tag_attributes(&tag) {
                    attribute.set_start_index(range.0);
                    attribute.set_end_index(range.1);
                    colours.insert(attribute);
                }
            }
            byte = range.1;
            at = next;
        }
        self.label.set_text(&code);
        self.label.set_attributes(Some(&colours));
    }
}

/// What a highlighting tag sets, as text attributes.
fn tag_attributes(tag: &gtk::TextTag) -> Vec<gtk::pango::Attribute> {
    let mut attributes = Vec::new();
    let channels = |rgba: gtk::gdk::RGBA| {
        let channel = |value: f32| (value.clamp(0.0, 1.0) * 65535.0).round() as u16;
        (channel(rgba.red()), channel(rgba.green()), channel(rgba.blue()))
    };
    if let Some(rgba) = tag.foreground_rgba().filter(|_| tag.is_foreground_set()) {
        let (red, green, blue) = channels(rgba);
        attributes.push(gtk::pango::AttrColor::new_foreground(red, green, blue).upcast());
    }
    if let Some(rgba) = tag.background_rgba().filter(|_| tag.is_background_set()) {
        let (red, green, blue) = channels(rgba);
        attributes.push(gtk::pango::AttrColor::new_background(red, green, blue).upcast());
    }
    if tag.is_weight_set() && tag.weight() >= 600 {
        attributes.push(gtk::pango::AttrInt::new_weight(gtk::pango::Weight::Bold).upcast());
    }
    if tag.is_style_set() && tag.style() != gtk::pango::Style::Normal {
        attributes.push(gtk::pango::AttrInt::new_style(tag.style()).upcast());
    }
    attributes
}

fn copy_button(shown: &Rc<Shown>, hooks: &BlockHooks) -> gtk::Button {
    let button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    button.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&button, &crate::i18n::gettext("Copy"), None);
    let (shown, toast) = (Rc::downgrade(shown), hooks.toast.clone());
    button.connect_clicked(move |button| {
        if let Some(shown) = shown.upgrade() {
            let code = shown.code.borrow().clone();
            crate::ui::clipboard::copy_text(button, code, |message| toast(message.to_owned()));
        }
    });
    button
}

fn insert_button(shown: &Rc<Shown>, hooks: &BlockHooks) -> gtk::Button {
    let button = gtk::Button::with_label(&crate::i18n::gettext("Insert"));
    button.add_css_class("flat");
    button.set_tooltip_text(Some(&crate::i18n::gettext("Insert Into the Editor")));
    let (shown, insert) = (Rc::downgrade(shown), hooks.insert.clone());
    button.connect_clicked(move |_| {
        if let Some(shown) = shown.upgrade() {
            insert(shown.code.borrow().clone());
        }
    });
    button
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    #[gtk4::test]
    fn insert_hands_over_the_code_as_it_now_reads() {
        let settings = crate::test_support::MemorySettings::new();
        let inserted = Rc::new(RefCell::new(None));
        let seen = inserted.clone();
        let hooks = BlockHooks {
            settings: settings.get().clone(),
            insert: Rc::new(move |code| {
                seen.replace(Some(code));
            }),
            toast: Rc::new(|_| {}),
        };
        let block = CodeBlock::new("SELECT", Some("sql"), &hooks);

        block.set_code("SELECT 1;");
        let insert = crate::test_support::descendants(block.widget())
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Insert"))
            .expect("the Insert button");
        insert.emit_clicked();

        assert_eq!(inserted.borrow().as_deref(), Some("SELECT 1;"));
        assert!(crate::test_support::unlabelled_icon_buttons(block.widget()).is_empty());
    }

    fn hooks(settings: &crate::test_support::MemorySettings) -> BlockHooks {
        BlockHooks {
            settings: settings.get().clone(),
            insert: Rc::new(|_| {}),
            toast: Rc::new(|_| {}),
        }
    }

    #[gtk4::test]
    fn a_block_asks_for_the_height_of_its_code_before_it_is_drawn() {
        let settings = crate::test_support::MemorySettings::new();
        let one = CodeBlock::new("SELECT 1;", Some("sql"), &hooks(&settings));
        let three = CodeBlock::new("SELECT 1\nFROM t\nWHERE x;", Some("sql"), &hooks(&settings));
        let height = |block: &CodeBlock| block.widget().measure(gtk::Orientation::Vertical, 400).1;

        assert!(
            height(&three) > height(&one) + 10,
            "{} against {}",
            height(&three),
            height(&one)
        );
    }

    #[gtk4::test]
    fn the_code_is_coloured_as_the_editor_colours_it() {
        let settings = crate::test_support::MemorySettings::new();
        let block = CodeBlock::new("SELECT name FROM users;", Some("sql"), &hooks(&settings));

        let label = crate::test_support::descendants(block.widget())
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .find(|label| label.text() == "SELECT name FROM users;")
            .expect("the code");
        let colours = label.attributes().expect("the colours");
        assert!(!colours.attributes().is_empty());
    }
}
