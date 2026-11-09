use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use sourceview5::prelude::*;

use crate::ui::handler_guard::HandlerGuard;

#[derive(Clone)]
pub(crate) struct BlockHooks {
    pub settings: Rc<tablepro_linux_platform::AppSettings>,
    pub insert: Rc<dyn Fn(String)>,
    pub toast: Rc<dyn Fn(String)>,
}

// A label measures streaming text synchronously; a text view waits for an idle
// that the running spinner can hold off.
pub(crate) struct CodeBlock {
    root: gtk::Box,
    shown: Rc<Shown>,
    settings: Rc<tablepro_linux_platform::AppSettings>,
    _theme: [HandlerGuard; 2],
}

struct Shown {
    code: RefCell<String>,
    label: gtk::Label,
    buffer: sourceview5::Buffer,
    colors: gtk::CssProvider,
    color_class: String,
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
            .build();
        label.add_css_class("monospace");
        let color_class = format!("code-{}", gtk::glib::uuid_string_random());
        label.add_css_class(&color_class);
        let colors = gtk::CssProvider::new();
        gtk::style_context_add_provider_for_display(
            &label.display(),
            &colors,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        let shown = Rc::new(Shown {
            code: RefCell::new(code.to_owned()),
            label,
            buffer,
            colors,
            color_class,
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
            Some(tablepro_linux_platform::settings::keys::STYLE_SCHEME),
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

    pub(crate) fn set_code(&self, code: &str) {
        if *self.shown.code.borrow() == code {
            return;
        }
        self.shown.code.replace(code.to_owned());
        self.shown.paint(&self.settings.style_scheme());
    }
}

impl Shown {
    fn paint(&self, scheme: &str) {
        let code = self.code.borrow();
        let scheme = crate::ui::style_scheme_resolver::scheme(scheme);
        self.buffer.set_style_scheme(scheme.as_ref());
        let text = gtk::TextTag::new(None);
        if let Some(style) = scheme.as_ref().and_then(|scheme| scheme.style("text")) {
            style.apply(&text);
        }
        // Only parsed colors enter CSS; a scheme file cannot supply declarations.
        let foreground = text.foreground_rgba().filter(|_| text.is_foreground_set());
        let background = text.background_rgba().filter(|_| text.is_background_set());
        self.colors.load_from_string(&format!(
            ".{} {{ padding: 8px 10px; color: {}; background-color: {}; }}",
            self.color_class,
            foreground.map_or_else(|| "inherit".to_owned(), |color| color.to_string()),
            background.map_or_else(|| "transparent".to_owned(), |color| color.to_string()),
        ));
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

impl Drop for Shown {
    fn drop(&mut self) {
        gtk::style_context_remove_provider_for_display(&self.label.display(), &self.colors);
    }
}

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

    fn background_pixel(label: &gtk::Label) -> [u8; 4] {
        use gtk::gsk::prelude::*;

        crate::test_support::after_next_frame(label);
        let snapshot = gtk::Snapshot::new();
        gtk::WidgetPaintable::new(Some(label)).snapshot(&snapshot, f64::from(label.width()), f64::from(label.height()));
        let node = snapshot.to_node().expect("painted label");
        let renderer = gtk::gsk::CairoRenderer::new();
        renderer.realize(None::<&gtk::gdk::Surface>).expect("Cairo renderer");
        let texture = renderer.render_texture(&node, None);
        let mut download = gtk::gdk::TextureDownloader::new(&texture);
        download.set_format(gtk::gdk::MemoryFormat::R8g8b8a8);
        let (bytes, _) = download.download_bytes();
        let pixel = bytes[..4].try_into().expect("one pixel");
        renderer.unrealize();
        pixel
    }

    #[gtk4::test]
    fn style_scheme_colors_paint_the_code_foreground_and_background_together() {
        adw::init().expect("libadwaita");
        let settings = crate::test_support::MemorySettings::new();
        let block = CodeBlock::new("SELECT name FROM users;", Some("sql"), &hooks(&settings));
        let window = crate::test_support::OwnedWindow::presented(
            gtk::Window::builder().child(block.widget()).default_width(400).build(),
        );
        let style = adw::StyleManager::default();
        let previous = style.color_scheme();
        for id in ["Adwaita-dark", "Adwaita"] {
            settings.get().set_style_scheme(id).expect("a scheme");
            for desktop in [adw::ColorScheme::ForceLight, adw::ColorScheme::ForceDark] {
                style.set_color_scheme(desktop);
                let scheme = block.shown.buffer.style_scheme().expect("a scheme");
                assert_eq!(scheme.id(), id);
                let text = gtk::TextTag::new(None);
                scheme.style("text").expect("text style").apply(&text);
                let foreground = text.foreground_rgba().expect("foreground");
                let background = text.background_rgba().expect("background");
                let pixel = background_pixel(&block.shown.label);
                assert_eq!(block.shown.label.color(), foreground);
                let byte = |value: f32| (value * 255.0).round() as u8;
                assert_eq!(
                    pixel,
                    [
                        byte(background.red()),
                        byte(background.green()),
                        byte(background.blue()),
                        255
                    ]
                );
                block.set_code("SELECT name FROM users WHERE id = 1;");
                assert_eq!(block.shown.label.text(), "SELECT name FROM users WHERE id = 1;");
            }
        }
        settings.get().set_style_scheme("").expect("automatic");
        style.set_color_scheme(adw::ColorScheme::ForceLight);
        assert_eq!(block.shown.buffer.style_scheme().expect("scheme").id(), "Adwaita");
        style.set_color_scheme(adw::ColorScheme::ForceDark);
        assert_eq!(block.shown.buffer.style_scheme().expect("scheme").id(), "Adwaita-dark");
        drop(window);
        style.set_color_scheme(previous);
    }

    #[gtk4::test]
    fn dropping_a_code_block_releases_its_paint_and_theme_handlers() {
        let settings = crate::test_support::MemorySettings::new();
        let references = Rc::weak_count(settings.get());
        let block = CodeBlock::new("plain code", Some("text"), &hooks(&settings));
        let shown = Rc::downgrade(&block.shown);
        let provider = block.shown.colors.downgrade();
        drop(block);
        assert!(shown.upgrade().is_none());
        assert!(provider.upgrade().is_none());
        assert_eq!(Rc::weak_count(settings.get()), references);
    }

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
