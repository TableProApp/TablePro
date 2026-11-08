use std::cell::{Cell, OnceCell, RefCell};
use std::collections::HashMap;

use gtk4 as gtk;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use libadwaita::subclass::prelude::*;
use tablepro_core::filter::{FilterOp, FilterValue};
use uuid::Uuid;

use super::DataGrid;
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{HighlightColor, HighlightRule, HighlightTarget};
use crate::ui::handler_guard::HandlerGuard;

const OPERATORS: [FilterOp; 17] = [
    FilterOp::Eq,
    FilterOp::NotEq,
    FilterOp::Gt,
    FilterOp::GtEq,
    FilterOp::Lt,
    FilterOp::LtEq,
    FilterOp::Contains,
    FilterOp::StartsWith,
    FilterOp::EndsWith,
    FilterOp::Like,
    FilterOp::NotLike,
    FilterOp::Ilike,
    FilterOp::IsNull,
    FilterOp::IsNotNull,
    FilterOp::In,
    FilterOp::NotIn,
    FilterOp::Between,
];

fn operator_label(op: FilterOp) -> String {
    match op {
        FilterOp::Eq => gettext("equals"),
        FilterOp::NotEq => gettext("doesn't equal"),
        FilterOp::Gt => gettext("greater than"),
        FilterOp::GtEq => gettext("at least"),
        FilterOp::Lt => gettext("less than"),
        FilterOp::LtEq => gettext("at most"),
        FilterOp::Contains => gettext("contains"),
        FilterOp::StartsWith => gettext("starts with"),
        FilterOp::EndsWith => gettext("ends with"),
        FilterOp::Like => gettext("matches pattern"),
        FilterOp::NotLike => gettext("doesn't match pattern"),
        FilterOp::Ilike => gettext("matches pattern, ignoring case"),
        FilterOp::IsNull => gettext("is NULL"),
        FilterOp::IsNotNull => gettext("is not NULL"),
        FilterOp::In => gettext("is one of"),
        FilterOp::NotIn => gettext("is none of"),
        FilterOp::Between => gettext("between"),
    }
}

fn color_label(color: HighlightColor) -> String {
    match color {
        HighlightColor::Red => gettext("Red"),
        HighlightColor::Orange => gettext("Orange"),
        HighlightColor::Yellow => gettext("Yellow"),
        HighlightColor::Green => gettext("Green"),
        HighlightColor::Blue => gettext("Blue"),
        HighlightColor::Purple => gettext("Purple"),
        HighlightColor::Gray => gettext("Gray"),
    }
}

fn blank_for(op: FilterOp) -> Option<FilterValue> {
    match op {
        FilterOp::IsNull | FilterOp::IsNotNull => None,
        FilterOp::In | FilterOp::NotIn => Some(FilterValue::List(vec![String::new()])),
        FilterOp::Between => Some(FilterValue::Pair(String::new(), String::new())),
        _ => Some(FilterValue::Single(String::new())),
    }
}

fn operand_summary(value: &Option<FilterValue>) -> String {
    let short = |text: &str| {
        let mut chars = text.chars();
        let mut result: String = chars.by_ref().take(40).collect();
        if chars.next().is_some() {
            result.push('…');
        }
        result
    };
    match value {
        None => String::new(),
        Some(FilterValue::Single(text)) => short(text),
        Some(FilterValue::Pair(low, high)) => {
            gettext_f("{from} to {to}", &[("from", &short(low)), ("to", &short(high))])
        }
        Some(FilterValue::List(values)) => {
            let mut result = values
                .iter()
                .take(3)
                .map(|value| short(value))
                .collect::<Vec<_>>()
                .join(", ");
            if values.len() > 3 {
                result.push('…');
            }
            result
        }
    }
}

fn operand_for(op: FilterOp, value: &Option<FilterValue>) -> Option<FilterValue> {
    match (op, value) {
        (FilterOp::IsNull | FilterOp::IsNotNull, _) => None,
        (FilterOp::In | FilterOp::NotIn, Some(FilterValue::List(_)))
        | (FilterOp::Between, Some(FilterValue::Pair(_, _))) => value.clone(),
        (FilterOp::In | FilterOp::NotIn | FilterOp::Between, _) => blank_for(op),
        (_, Some(FilterValue::Single(_))) => value.clone(),
        _ => blank_for(op),
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct HighlightDialog {
        pub(super) grid: glib::WeakRef<DataGrid>,
        pub(super) list: OnceCell<gtk::Box>,
        pub(super) add: OnceCell<gtk::Button>,
        pub(super) rows: RefCell<HashMap<Uuid, glib::WeakRef<adw::ExpanderRow>>>,
        pub(super) watches: RefCell<Vec<HandlerGuard>>,
        pub(super) updating: Cell<bool>,
        pub(super) queued: Cell<bool>,
        pub(super) drag_id: OnceCell<Uuid>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for HighlightDialog {
        const NAME: &'static str = "TableProHighlightDialog";
        type Type = super::HighlightDialog;
        type ParentType = adw::Dialog;
    }

    impl ObjectImpl for HighlightDialog {
        fn dispose(&self) {
            self.watches.borrow_mut().clear();
        }
    }
    impl WidgetImpl for HighlightDialog {}
    impl AdwDialogImpl for HighlightDialog {}
}

glib::wrapper! {
    pub struct HighlightDialog(ObjectSubclass<imp::HighlightDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) fn build(grid: &DataGrid) -> adw::Dialog {
    let dialog: HighlightDialog = glib::Object::new();
    dialog.setup(grid);
    dialog.upcast()
}

pub(crate) fn present(grid: &DataGrid) {
    if let Some(dialog) = grid.imp().highlight_dialog.upgrade() {
        dialog.present(Some(grid));
        return;
    }
    let dialog = build(grid);
    grid.imp().highlight_dialog.set(Some(&dialog));
    dialog.present(Some(grid));
}

impl HighlightDialog {
    fn setup(&self, grid: &DataGrid) {
        self.imp().grid.set(Some(grid));
        let _ = self.imp().drag_id.set(Uuid::new_v4());
        self.set_title(&gettext("Highlight Rules"));
        self.set_content_width(480);
        self.set_content_height(600);
        let header = adw::HeaderBar::new();
        let add = gtk::Button::with_label(&gettext("Add Rule"));
        add.add_css_class("suggested-action");
        add.set_sensitive(!grid.grid_columns().is_empty());
        header.pack_end(&add);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 18);
        list.set_margin_top(18);
        list.set_margin_bottom(18);
        list.set_margin_start(18);
        list.set_margin_end(18);
        let description = gtk::Label::builder()
            .label(gettext(
                "The first matching rule sets the colour. A cell rule takes priority over a row rule.",
            ))
            .wrap(true)
            .xalign(0.0)
            .build();
        description.add_css_class("dimmed");
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        description.set_margin_start(18);
        description.set_margin_end(18);
        description.set_margin_top(18);
        body.append(&description);
        body.append(&list);
        let clamp = adw::Clamp::builder().maximum_size(600).child(&body).build();
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&clamp)
            .build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&scroll));
        self.set_child(Some(&toolbar));
        self.set_focus(Some(&add));
        let _ = self.imp().list.set(list);
        let _ = self.imp().add.set(add.clone());
        add.connect_clicked(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |_| dialog.add_rule()
        ));
        self.rebuild(None);
        let columns = grid.column_view().columns();
        let handler = columns.connect_items_changed(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |_, _, _, _| dialog.queue_rebuild()
        ));
        self.imp()
            .watches
            .borrow_mut()
            .push(HandlerGuard::new(&columns, handler));
        let handler = grid.connect_local(
            "highlight-rules-changed",
            false,
            glib::clone!(
                #[weak(rename_to = dialog)]
                self,
                #[upgrade_or]
                None,
                move |_| {
                    if !dialog.imp().updating.get() {
                        dialog.queue_rebuild();
                    }
                    None
                }
            ),
        );
        self.imp().watches.borrow_mut().push(HandlerGuard::new(grid, handler));
        self.connect_closed(|dialog| {
            dialog.imp().watches.borrow_mut().clear();
            if let Some(grid) = dialog.imp().grid.upgrade() {
                grid.imp().highlight_dialog.set(None::<&adw::Dialog>);
            }
        });
    }

    fn queue_rebuild(&self) {
        if self.imp().queued.replace(true) {
            return;
        }
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(dialog) = weak.upgrade() {
                dialog.imp().queued.set(false);
                let focus = dialog.focus().and_then(|focus| {
                    dialog.imp().rows.borrow().iter().find_map(|(id, row)| {
                        row.upgrade()
                            .filter(|row| focus.is_ancestor(row) || focus == *row.upcast_ref::<gtk::Widget>())
                            .map(|_| *id)
                    })
                });
                dialog.rebuild(focus);
            }
        });
    }

    fn publish(&self, grid: &DataGrid, rules: Vec<HighlightRule>) {
        self.imp().updating.set(true);
        grid.set_highlight_rules(rules);
        self.imp().updating.set(false);
    }

    fn add_rule(&self) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let Some(first) = grid.grid_columns().first().cloned() else {
            return;
        };
        let rule = HighlightRule::new(first.name.clone());
        let id = rule.id;
        let mut rules = grid.highlight_rules();
        rules.push(rule);
        self.publish(&grid, rules);
        self.rebuild(Some(id));
    }

    fn edit(&self, id: Uuid, change: impl FnOnce(&mut HighlightRule)) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let mut rules = grid.highlight_rules();
        let Some(rule) = rules.iter_mut().find(|rule| rule.id == id) else {
            return;
        };
        change(rule);
        self.publish(&grid, rules);
        self.update_summary(id);
    }

    fn update_summary(&self, id: Uuid) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let Some(rule) = grid.highlight_rules().into_iter().find(|rule| rule.id == id) else {
            return;
        };
        let Some(row) = self.imp().rows.borrow().get(&id).and_then(glib::WeakRef::upgrade) else {
            return;
        };
        let available = grid
            .grid_columns()
            .iter()
            .filter(|column| column.name == rule.column)
            .nth(rule.column_occurrence)
            .is_some();
        let summary = if !available {
            gettext("Column unavailable. Choose another column to use this rule.")
        } else if !rule.enabled {
            gettext("Disabled")
        } else if !rule.is_valid() {
            gettext("Enter a value to use this rule.")
        } else {
            let target = match rule.target {
                HighlightTarget::Row => gettext("Row"),
                HighlightTarget::Cell => gettext("Cell"),
            };
            gettext_f(
                "{column} {condition} {value}; {target}, {colour}",
                &[
                    ("column", &rule.column),
                    ("condition", &operator_label(rule.op)),
                    ("value", &operand_summary(&rule.value)),
                    ("target", &target),
                    ("colour", &color_label(rule.color)),
                ],
            )
        };
        row.set_subtitle(&summary);
    }

    fn rebuild(&self, focus: Option<Uuid>) {
        let Some(list) = self.imp().list.get() else {
            return;
        };
        let expanded: Vec<Uuid> = self
            .imp()
            .rows
            .borrow()
            .iter()
            .filter_map(|(id, row)| row.upgrade().filter(|row| row.is_expanded()).map(|_| *id))
            .collect();
        while let Some(child) = list.first_child() {
            list.remove(&child);
        }
        self.imp().rows.borrow_mut().clear();
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let rules = grid.highlight_rules();
        if let Some(add) = self.imp().add.get() {
            add.set_sensitive(!grid.grid_columns().is_empty());
        }
        if rules.is_empty() {
            let empty = adw::StatusPage::builder()
                .title(gettext("No Highlight Rules"))
                .description(gettext("Add a rule to colour matching rows or cells."))
                .icon_name("document-edit-symbolic")
                .build();
            list.append(&empty);
        }
        for (index, rule) in rules.iter().enumerate() {
            let group = adw::PreferencesGroup::new();
            let row = self.rule_row(rule, index, rules.len());
            group.add(&row);
            list.append(&group);
            self.imp().rows.borrow_mut().insert(rule.id, row.downgrade());
            self.update_summary(rule.id);
            row.set_expanded(expanded.contains(&rule.id) || focus == Some(rule.id));
            if focus == Some(rule.id) {
                row.grab_focus();
            }
        }
        if rules.is_empty()
            && focus.is_some()
            && let Some(add) = self.imp().add.get()
        {
            add.grab_focus();
        }
    }

    fn remove(&self, id: Uuid) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let mut rules = grid.highlight_rules();
        let Some(index) = rules.iter().position(|rule| rule.id == id) else {
            return;
        };
        rules.remove(index);
        let next = rules
            .get(index.min(rules.len().saturating_sub(1)))
            .map(|rule| rule.id)
            .unwrap_or(id);
        self.publish(&grid, rules);
        self.rebuild(Some(next));
    }

    fn move_rule(&self, id: Uuid, before: Uuid) -> bool {
        let Some(grid) = self.imp().grid.upgrade() else {
            return false;
        };
        let mut rules = grid.highlight_rules();
        let (Some(from), Some(to)) = (
            rules.iter().position(|rule| rule.id == id),
            rules.iter().position(|rule| rule.id == before),
        ) else {
            return false;
        };
        if from == to {
            return false;
        }
        let rule = rules.remove(from);
        rules.insert(to, rule);
        self.publish(&grid, rules);
        self.rebuild(Some(id));
        true
    }

    fn step(&self, id: Uuid, up: bool) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let rules = grid.highlight_rules();
        let Some(index) = rules.iter().position(|rule| rule.id == id) else {
            return;
        };
        let next = if up { index.checked_sub(1) } else { index.checked_add(1) };
        if let Some(target) = next.and_then(|next| rules.get(next)) {
            self.move_rule(id, target.id);
        }
    }

    fn rule_row(&self, rule: &HighlightRule, index: usize, count: usize) -> adw::ExpanderRow {
        let id = rule.id;
        let row = adw::ExpanderRow::builder()
            .title(gettext_f("Rule {number}", &[("number", &(index + 1).to_string())]))
            .use_markup(false)
            .subtitle_lines(2)
            .build();
        self.order_controls(&row, id, index, count);
        let enabled = adw::SwitchRow::builder()
            .title(gettext("Enabled"))
            .active(rule.enabled)
            .build();
        enabled.connect_active_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| dialog.edit(id, |rule| rule.enabled = row.is_active())
        ));
        row.add_row(&enabled);
        self.column_control(&row, rule);
        let condition = combo(
            &gettext("Condition"),
            &OPERATORS.iter().map(|op| operator_label(*op)).collect::<Vec<_>>(),
            OPERATORS.iter().position(|op| *op == rule.op).unwrap_or(0),
        );
        condition.connect_selected_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| {
                if let Some(op) = OPERATORS.get(row.selected() as usize).copied() {
                    dialog.edit(id, |rule| {
                        rule.op = op;
                        rule.value = blank_for(op);
                    });
                    dialog.rebuild(Some(id));
                }
            }
        ));
        row.add_row(&condition);
        self.value_controls(&row, rule);
        let color = combo(
            &gettext("Colour"),
            &HighlightColor::ALL
                .iter()
                .map(|color| color_label(*color))
                .collect::<Vec<_>>(),
            HighlightColor::ALL
                .iter()
                .position(|color| *color == rule.color)
                .unwrap_or(0),
        );
        color.connect_selected_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| {
                if let Some(color) = HighlightColor::ALL.get(row.selected() as usize).copied() {
                    dialog.edit(id, |rule| rule.color = color);
                }
            }
        ));
        row.add_row(&color);
        let target = combo(
            &gettext("Apply to"),
            &[gettext("Row"), gettext("Cell")],
            usize::from(rule.target == HighlightTarget::Cell),
        );
        target.connect_selected_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| dialog.edit(id, |rule| {
                rule.target = if row.selected() == 1 {
                    HighlightTarget::Cell
                } else {
                    HighlightTarget::Row
                };
            })
        ));
        row.add_row(&target);
        let case = adw::SwitchRow::builder()
            .title(gettext("Match Case"))
            .active(rule.case_sensitive)
            .sensitive(!matches!(
                rule.op,
                FilterOp::IsNull | FilterOp::IsNotNull | FilterOp::Ilike
            ))
            .build();
        case.connect_active_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| dialog.edit(id, |rule| rule.case_sensitive = row.is_active())
        ));
        row.add_row(&case);
        row
    }

    fn column_control(&self, row: &adw::ExpanderRow, rule: &HighlightRule) {
        let Some(grid) = self.imp().grid.upgrade() else {
            return;
        };
        let columns = grid.grid_columns();
        let choices: Vec<(String, usize)> = columns
            .iter()
            .enumerate()
            .map(|(index, column)| {
                (
                    column.name.clone(),
                    columns[..index]
                        .iter()
                        .filter(|other| other.name == column.name)
                        .count(),
                )
            })
            .collect();
        let mut labels: Vec<String> = choices
            .iter()
            .map(|(name, occurrence)| {
                if choices.iter().filter(|(other, _)| other == name).count() > 1 {
                    gettext_f(
                        "{column} ({number})",
                        &[("column", name), ("number", &(occurrence + 1).to_string())],
                    )
                } else {
                    name.clone()
                }
            })
            .collect();
        let selected = choices
            .iter()
            .position(|(name, occurrence)| *name == rule.column && *occurrence == rule.column_occurrence)
            .unwrap_or_else(|| {
                labels.push(gettext_f("{column} (unavailable)", &[("column", &rule.column)]));
                labels.len() - 1
            });
        let column = combo(&gettext("Column"), &labels, selected);
        let id = rule.id;
        column.connect_selected_notify(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            move |row| {
                if let Some((name, occurrence)) = choices.get(row.selected() as usize) {
                    dialog.edit(id, |rule| {
                        rule.column.clone_from(name);
                        rule.column_occurrence = *occurrence;
                    });
                }
            }
        ));
        row.add_row(&column);
    }

    fn value_controls(&self, row: &adw::ExpanderRow, rule: &HighlightRule) {
        let id = rule.id;
        let value = operand_for(rule.op, &rule.value);
        match &value {
            None => {}
            Some(FilterValue::Single(value)) => {
                let entry = entry(&gettext("Value"), value);
                entry.connect_changed(glib::clone!(
                    #[weak(rename_to = dialog)]
                    self,
                    move |entry| dialog.edit(id, |rule| rule.value =
                        Some(FilterValue::Single(entry.text().to_string())))
                ));
                row.add_row(&entry);
            }
            Some(FilterValue::Pair(low, high)) => {
                for (first, title, text) in [(true, gettext("From"), low), (false, gettext("To"), high)] {
                    let entry = entry(&title, text);
                    entry.connect_changed(glib::clone!(
                        #[weak(rename_to = dialog)]
                        self,
                        move |entry| dialog.edit(id, |rule| {
                            rule.value = operand_for(rule.op, &rule.value);
                            if let Some(FilterValue::Pair(low, high)) = &mut rule.value {
                                if first {
                                    *low = entry.text().to_string();
                                } else {
                                    *high = entry.text().to_string();
                                }
                            }
                        })
                    ));
                    row.add_row(&entry);
                }
            }
            Some(FilterValue::List(values)) => {
                for (index, text) in values.iter().enumerate() {
                    let entry = entry(
                        &gettext_f("Value {number}", &[("number", &(index + 1).to_string())]),
                        text,
                    );
                    entry.connect_changed(glib::clone!(
                        #[weak(rename_to = dialog)]
                        self,
                        move |entry| dialog.edit(id, |rule| {
                            rule.value = operand_for(rule.op, &rule.value);
                            if let Some(FilterValue::List(values)) = &mut rule.value
                                && let Some(value) = values.get_mut(index)
                            {
                                *value = entry.text().to_string();
                            }
                        })
                    ));
                    let remove = gtk::Button::builder()
                        .icon_name("edit-delete-symbolic")
                        .valign(gtk::Align::Center)
                        .tooltip_text(gettext("Remove Value"))
                        .build();
                    remove.add_css_class("flat");
                    remove.connect_clicked(glib::clone!(
                        #[weak(rename_to = dialog)]
                        self,
                        move |_| {
                            dialog.edit(id, |rule| {
                                rule.value = operand_for(rule.op, &rule.value);
                                if let Some(FilterValue::List(values)) = &mut rule.value
                                    && index < values.len()
                                {
                                    values.remove(index);
                                }
                            });
                            dialog.rebuild(Some(id));
                        }
                    ));
                    entry.add_suffix(&remove);
                    row.add_row(&entry);
                }
                let add = adw::ButtonRow::builder()
                    .title(gettext("Add Value"))
                    .start_icon_name("list-add-symbolic")
                    .build();
                add.connect_activated(glib::clone!(
                    #[weak(rename_to = dialog)]
                    self,
                    move |_| {
                        dialog.edit(id, |rule| {
                            rule.value = operand_for(rule.op, &rule.value);
                            if let Some(FilterValue::List(values)) = &mut rule.value {
                                values.push(String::new());
                            }
                        });
                        dialog.rebuild(Some(id));
                    }
                ));
                row.add_row(&add);
            }
        }
    }

    fn order_controls(&self, row: &adw::ExpanderRow, id: Uuid, index: usize, count: usize) {
        let menu = gio::Menu::new();
        menu.append(Some(&gettext("Move Up")), Some("rule.up"));
        menu.append(Some(&gettext("Move Down")), Some("rule.down"));
        menu.append(Some(&gettext("Remove Rule")), Some("rule.remove"));
        let actions = gio::SimpleActionGroup::new();
        for (name, enabled) in [("up", index > 0), ("down", index + 1 < count), ("remove", true)] {
            let action = gio::SimpleAction::new(name, None);
            action.set_enabled(enabled);
            action.connect_activate(glib::clone!(
                #[weak(rename_to = dialog)]
                self,
                move |action, _| {
                    match action.name().as_str() {
                        "up" => dialog.step(id, true),
                        "down" => dialog.step(id, false),
                        _ => dialog.remove(id),
                    }
                }
            ));
            actions.add_action(&action);
        }
        row.insert_action_group("rule", Some(&actions));
        let button = gtk::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .menu_model(&menu)
            .valign(gtk::Align::Center)
            .tooltip_text(gettext("Rule Actions"))
            .build();
        button.add_css_class("flat");
        row.add_suffix(&button);
        let handle = gtk::Image::from_icon_name("list-drag-handle-symbolic");
        handle.set_tooltip_text(Some(&gettext("Drag to Reorder")));
        row.add_prefix(&handle);
        let source = gtk::DragSource::builder().actions(gdk::DragAction::MOVE).build();
        let Some(drag_id) = self.imp().drag_id.get() else {
            return;
        };
        let token = format!("{drag_id}:{id}");
        source.connect_prepare(move |_, _, _| Some(gdk::ContentProvider::for_value(&token.to_value())));
        handle.add_controller(source);
        let target = gtk::DropTarget::new(String::static_type(), gdk::DragAction::MOVE);
        target.connect_drop(glib::clone!(
            #[weak(rename_to = dialog)]
            self,
            #[upgrade_or]
            false,
            move |_, value, _, _| {
                let Ok(token) = value.get::<String>() else {
                    return false;
                };
                let Some((owner, rule)) = token.split_once(':') else {
                    return false;
                };
                if Uuid::parse_str(owner).ok().as_ref() != dialog.imp().drag_id.get() {
                    return false;
                }
                let Ok(from) = Uuid::parse_str(rule) else {
                    return false;
                };
                dialog.move_rule(from, id)
            }
        ));
        row.add_controller(target);
    }
}

fn combo(title: &str, labels: &[String], selected: usize) -> adw::ComboRow {
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    adw::ComboRow::builder()
        .title(title)
        .model(&gtk::StringList::new(&refs))
        .selected(selected as u32)
        .use_markup(false)
        .build()
}

fn entry(title: &str, text: &str) -> adw::EntryRow {
    adw::EntryRow::builder().title(title).text(text).build()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::test_support::{descendants, drain_main_context};
    use crate::ui::data_grid::GridSorting;
    use crate::ui::data_grid::test_grid::{Grid, named, two_text_columns, two_text_values};

    fn editor(grid: &Grid) -> HighlightDialog {
        build(&grid.grid).downcast().expect("highlight dialog")
    }

    fn entry_named(dialog: &HighlightDialog, title: &str) -> adw::EntryRow {
        descendants(dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .find(|row| row.title() == title)
            .expect("entry row")
    }

    fn combo_named(dialog: &HighlightDialog, title: &str) -> adw::ComboRow {
        descendants(dialog)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::ComboRow>().ok())
            .find(|row| row.title() == title)
            .expect("combo row")
    }

    #[gtk4::test]
    fn add_button_creates_a_rule_and_entry_changes_apply_immediately() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let dialog = editor(&grid);
        dialog.imp().add.get().expect("add button").emit_clicked();
        let rules = grid.grid.highlight_rules();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].column, "id");
        entry_named(&dialog, "Value").set_text("1");
        assert_eq!(
            grid.grid.highlight_rules()[0].value,
            Some(FilterValue::Single("1".to_owned()))
        );
    }

    #[test]
    fn malformed_operands_can_be_repaired_without_losing_valid_values() {
        let extra = Some(FilterValue::Single("ignored".to_owned()));
        assert_eq!(operand_for(FilterOp::IsNull, &extra), None);
        assert_eq!(operand_for(FilterOp::Between, &extra), blank_for(FilterOp::Between));
        let pair = Some(FilterValue::Pair("a, b".to_owned(), " c ".to_owned()));
        assert_eq!(operand_for(FilterOp::Between, &pair), pair);
    }

    #[gtk4::test]
    fn edits_follow_rule_identity_after_reordering_and_removal() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let first = HighlightRule::new("id");
        let second = HighlightRule::new("name");
        grid.grid.set_highlight_rules(vec![first.clone(), second.clone()]);
        let dialog = editor(&grid);
        let old_entry = entry_named(&dialog, "Value");
        let row = dialog
            .imp()
            .rows
            .borrow()
            .get(&first.id)
            .and_then(glib::WeakRef::upgrade)
            .expect("first row");
        row.activate_action("rule.down", None).expect("move action");
        old_entry.set_text("99");
        let rules = grid.grid.highlight_rules();
        assert_eq!(rules[1].id, first.id);
        assert_eq!(rules[1].value, Some(FilterValue::Single("99".to_owned())));
        assert_eq!(rules[0].id, second.id);
        dialog.remove(first.id);
        old_entry.set_text("100");
        assert_eq!(grid.grid.highlight_rules(), [second]);
    }

    #[gtk4::test]
    fn missing_and_duplicate_columns_keep_their_identity() {
        let grid = Grid::open(vec![named("same", "text", false), named("same", "text", false)], vec![]);
        let mut rule = HighlightRule::new("gone");
        rule.value = Some(FilterValue::Single("x".to_owned()));
        grid.grid.set_highlight_rules(vec![rule]);
        let dialog = editor(&grid);
        let column = combo_named(&dialog, "Column");
        assert_eq!(column.selected(), 2);
        let selected = column
            .selected_item()
            .and_downcast::<gtk::StringObject>()
            .expect("missing choice");
        assert!(selected.string().contains("unavailable"));
        column.set_selected(1);
        let rules = grid.grid.highlight_rules();
        assert_eq!(rules[0].column, "same");
        assert_eq!(rules[0].column_occurrence, 1);
        drop(dialog);
        let dialog = editor(&grid);
        assert_eq!(combo_named(&dialog, "Column").selected(), 1);
    }

    #[gtk4::test]
    fn changing_columns_updates_an_open_dialog() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        grid.grid.set_highlight_rules(vec![HighlightRule::new("name")]);
        let dialog = editor(&grid);
        let mut columns = grid.grid.grid_columns().to_vec();
        columns.truncate(1);
        columns[0].name = "replacement".to_owned();
        grid.grid.set_columns(Arc::from(columns), GridSorting::Client, None);
        drain_main_context();
        let column = combo_named(&dialog, "Column");
        assert_eq!(column.selected(), 1);
        column.set_selected(0);
        assert_eq!(grid.grid.highlight_rules()[0].column, "replacement");
    }

    #[gtk4::test]
    fn list_and_range_fields_preserve_commas_and_spaces() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let mut rule = HighlightRule::new("name");
        rule.op = FilterOp::In;
        rule.value = Some(FilterValue::List(vec!["a, b".to_owned(), " c ".to_owned()]));
        grid.grid.set_highlight_rules(vec![rule.clone()]);
        let dialog = editor(&grid);
        assert_eq!(entry_named(&dialog, "Value 1").text(), "a, b");
        entry_named(&dialog, "Value 2").set_text(" d, e ");
        assert_eq!(
            grid.grid.highlight_rules()[0].value,
            Some(FilterValue::List(vec!["a, b".to_owned(), " d, e ".to_owned()]))
        );
        let condition = combo_named(&dialog, "Condition");
        condition.set_selected(
            OPERATORS
                .iter()
                .position(|op| *op == FilterOp::Between)
                .expect("between") as u32,
        );
        entry_named(&dialog, "From").set_text("a, b");
        entry_named(&dialog, "To").set_text("z, x");
        assert_eq!(
            grid.grid.highlight_rules()[0].value,
            Some(FilterValue::Pair("a, b".to_owned(), "z, x".to_owned()))
        );
    }

    #[gtk4::test]
    fn dialog_widgets_and_watchers_are_released() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        grid.grid.set_highlight_rules(vec![HighlightRule::new("id")]);
        let dialog = editor(&grid);
        let weak_dialog = dialog.downgrade();
        let weak_value = entry_named(&dialog, "Value").downgrade();
        drop(dialog);
        drain_main_context();
        assert!(weak_dialog.upgrade().is_none());
        assert!(weak_value.upgrade().is_none());
        grid.grid.set_highlight_rules(Vec::new());
        drain_main_context();
    }

    #[gtk4::test]
    fn external_rule_changes_refresh_the_dialog_and_empty_columns_disable_add() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        let dialog = editor(&grid);
        grid.grid.set_highlight_rules(vec![HighlightRule::new("name")]);
        drain_main_context();
        assert_eq!(dialog.imp().rows.borrow().len(), 1);
        grid.grid.set_columns(Arc::from([]), GridSorting::Client, None);
        drain_main_context();
        assert!(!dialog.imp().add.get().expect("add button").is_sensitive());
        assert_eq!(grid.grid.highlight_rules().len(), 1);
    }
}
