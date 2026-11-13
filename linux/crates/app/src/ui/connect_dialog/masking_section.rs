//! The Data Masking group: the rules that hide this connection's values
//! on screen and on every path out of the app (core ADR 0028).

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::masking::{MaskingRule, MaskingStyle, MaskingTarget};
use uuid::Uuid;

use super::ConnectDialog;
use crate::i18n::{gettext, gettext_f};
use crate::ui::masking_text::{style_label, target_label};

// One rule's rows. The expander names the pattern, and its rows hold what it applies to, the pattern and the style.
#[derive(Debug)]
pub struct RuleRow {
    id: Uuid,
    expander: adw::ExpanderRow,
    target: adw::ComboRow,
    pattern: adw::EntryRow,
    style: adw::ComboRow,
}

impl RuleRow {
    fn rule(&self) -> MaskingRule {
        MaskingRule {
            id: self.id,
            pattern: self.pattern.text().to_string(),
            target: picked_target(&self.target),
            style: picked_style(&self.style),
        }
    }
}

fn picked_target(row: &adw::ComboRow) -> MaskingTarget {
    MaskingTarget::ALL
        .get(row.selected() as usize)
        .copied()
        .unwrap_or_default()
}

fn picked_style(row: &adw::ComboRow) -> MaskingStyle {
    MaskingStyle::ALL
        .get(row.selected() as usize)
        .copied()
        .unwrap_or(MaskingStyle::Full)
}

impl ConnectDialog {
    pub(super) fn show_masking(&self, rules: &[MaskingRule]) {
        for rule in rules {
            self.add_masking_rule(rule, false);
        }
        let weak = self.downgrade();
        self.imp().add_masking_rule_row.connect_activated(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.add_masking_rule(&MaskingRule::new("", MaskingTarget::Column, MaskingStyle::Full), true);
            }
        });
    }

    // The rules as the rows hold them, blank patterns left out.
    pub(super) fn masking_rules(&self) -> Vec<MaskingRule> {
        let rules: Vec<MaskingRule> = self.imp().masking_rules.borrow().iter().map(RuleRow::rule).collect();
        super::connect_form::saved_rules(&rules)
    }

    fn add_masking_rule(&self, rule: &MaskingRule, focus: bool) {
        let imp = self.imp();
        let row = rule_row(rule);
        let remove = gtk::Button::builder()
            .icon_name("edit-delete-symbolic")
            .valign(gtk::Align::Center)
            .tooltip_text(gettext("Remove Rule"))
            .css_classes(["flat"])
            .build();
        let (weak, id) = (self.downgrade(), rule.id);
        remove.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.remove_masking_rule(id);
            }
        });
        row.expander.add_suffix(&remove);
        // Before Add Rule, which stays last.
        let group = &imp.masking_group;
        group.remove(&*imp.add_masking_rule_row);
        group.add(&row.expander);
        group.add(&*imp.add_masking_rule_row);
        if focus {
            row.expander.set_expanded(true);
            row.pattern.grab_focus();
        }
        imp.masking_rules.borrow_mut().push(row);
    }

    fn remove_masking_rule(&self, id: Uuid) {
        let imp = self.imp();
        let mut rows = imp.masking_rules.borrow_mut();
        if let Some(at) = rows.iter().position(|row| row.id == id) {
            let row = rows.remove(at);
            imp.masking_group.remove(&row.expander);
        }
        drop(rows);
        imp.add_masking_rule_row.grab_focus();
    }
}

fn rule_row(rule: &MaskingRule) -> RuleRow {
    let expander = adw::ExpanderRow::builder().use_markup(false).build();
    let targets: Vec<String> = MaskingTarget::ALL.iter().map(|target| target_label(*target)).collect();
    let target = combo(&gettext("Applies To"), &targets, target_index(rule.target));
    let pattern = adw::EntryRow::builder()
        .title(pattern_title(rule.target))
        .text(&rule.pattern)
        .build();
    let styles: Vec<String> = MaskingStyle::ALL.iter().map(|style| style_label(*style)).collect();
    let style = combo(&gettext("Style"), &styles, style_index(rule.style));
    expander.add_row(&target);
    expander.add_row(&pattern);
    expander.add_row(&style);
    let row = RuleRow {
        id: rule.id,
        expander,
        target,
        pattern,
        style,
    };
    describe(&row.expander, &row.target, &row.pattern, &row.style);
    let (expander, entry, kind, shown) = (
        row.expander.downgrade(),
        row.pattern.downgrade(),
        row.target.downgrade(),
        row.style.downgrade(),
    );
    let follow = move || {
        if let (Some(expander), Some(pattern), Some(target), Some(style)) =
            (expander.upgrade(), entry.upgrade(), kind.upgrade(), shown.upgrade())
        {
            describe(&expander, &target, &pattern, &style);
        }
    };
    let follow = std::rc::Rc::new(follow);
    let on_target = follow.clone();
    row.target.connect_selected_notify(move |_| on_target());
    let on_pattern = follow.clone();
    row.pattern.connect_changed(move |_| on_pattern());
    row.style.connect_selected_notify(move |_| follow());
    row
}

// The expander names the rule; the pattern row's title says what kind of name it takes.
fn describe(expander: &adw::ExpanderRow, target: &adw::ComboRow, pattern: &adw::EntryRow, style: &adw::ComboRow) {
    let (target, style) = (picked_target(target), picked_style(style));
    let text = pattern.text();
    let title = match text.trim() {
        "" => gettext("New Rule"),
        typed => typed.to_owned(),
    };
    expander.set_title(&title);
    expander.set_subtitle(&gettext_f(
        "{target} · {style}",
        &[("target", &target_label(target)), ("style", &style_label(style))],
    ));
    pattern.set_title(&pattern_title(target));
}

fn pattern_title(target: MaskingTarget) -> String {
    match target {
        MaskingTarget::Column => gettext("Column, such as *.email"),
        MaskingTarget::Type => gettext("Type, such as uuid"),
    }
}

fn target_index(target: MaskingTarget) -> u32 {
    MaskingTarget::ALL
        .iter()
        .position(|known| *known == target)
        .unwrap_or_default() as u32
}

fn style_index(style: MaskingStyle) -> u32 {
    MaskingStyle::ALL
        .iter()
        .position(|known| *known == style)
        .unwrap_or_default() as u32
}

fn combo(title: &str, labels: &[String], selected: u32) -> adw::ComboRow {
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    adw::ComboRow::builder()
        .title(title)
        .model(&gtk::StringList::new(&refs))
        .selected(selected)
        .use_markup(false)
        .build()
}

#[cfg(test)]
impl RuleRow {
    pub(super) fn expander(&self) -> &adw::ExpanderRow {
        &self.expander
    }

    pub(super) fn target(&self) -> &adw::ComboRow {
        &self.target
    }

    pub(super) fn pattern(&self) -> &adw::EntryRow {
        &self.pattern
    }

    pub(super) fn style(&self) -> &adw::ComboRow {
        &self.style
    }
}
