use std::cmp::Ordering;

use tablepro_core::value::order::natural_text_order;
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;
use uuid::Uuid;

use crate::{ConnectionColor, ConnectionGroupName, ConnectionIcon, GroupIcon, SymbolName};

// Keep unknown raw values until the user changes that field.

// As Swift's `UUID(uuidString:)` reads one: hyphenated, in either case.
pub(super) fn record_id(raw: &str) -> Option<Uuid> {
    (raw.len() == 36).then(|| Uuid::try_parse(raw).ok()).flatten()
}

// `uuidString` is upper case, so an id the core writes reads the same in a Swift log or a string compare.
pub(super) fn id_value(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

pub(super) fn group_name(raw: Option<&str>) -> Option<ConnectionGroupName> {
    raw.and_then(ConnectionGroupName::from_stored)
}

// Keep macOS colour spellings so existing readers recognize the records.
const COLORS: [(ConnectionColor, &str); 9] = [
    (ConnectionColor::Red, "Red"),
    (ConnectionColor::Orange, "Orange"),
    (ConnectionColor::Yellow, "Yellow"),
    (ConnectionColor::Green, "Green"),
    (ConnectionColor::Blue, "Blue"),
    (ConnectionColor::Purple, "Purple"),
    (ConnectionColor::Pink, "Pink"),
    (ConnectionColor::Slate, "Gray"),
    (ConnectionColor::Teal, "Teal"),
];

const NO_COLOR: &str = "None";

pub(super) fn color(raw: Option<&str>) -> Option<ConnectionColor> {
    let raw = raw?;
    COLORS.iter().find(|(_, name)| *name == raw).map(|(color, _)| *color)
}

pub(super) fn color_value(color: Option<ConnectionColor>) -> String {
    color
        .and_then(|color| COLORS.iter().find(|(known, _)| *known == color))
        .map_or(NO_COLOR, |(_, name)| *name)
        .to_owned()
}

// Use SF Symbol names so the same record draws a known icon on macOS.
const NAMED_SYMBOLS: [(ConnectionIcon, &str); 15] = [
    (ConnectionIcon::Server, "server.rack"),
    (ConnectionIcon::Computer, "desktopcomputer"),
    (ConnectionIcon::Disk, "externaldrive"),
    (ConnectionIcon::Folder, "folder"),
    (ConnectionIcon::Home, "house"),
    (ConnectionIcon::Cloud, "cloud"),
    (ConnectionIcon::Web, "globe"),
    (ConnectionIcon::Terminal, "terminal"),
    (ConnectionIcon::Package, "shippingbox"),
    (ConnectionIcon::Lab, "flask"),
    (ConnectionIcon::Tools, "wrench.and.screwdriver"),
    (ConnectionIcon::Star, "star"),
    (ConnectionIcon::Warning, "exclamationmark.triangle"),
    (ConnectionIcon::Shield, "shield"),
    (ConnectionIcon::Lock, "lock"),
];

pub(super) fn icon(raw: Option<&str>) -> Option<GroupIcon> {
    let symbol = SymbolName::new(raw?)?;
    let named = NAMED_SYMBOLS
        .iter()
        .find(|(_, name)| *name == symbol.as_str())
        .map(|(icon, _)| *icon);
    Some(named.map_or(GroupIcon::Symbol(symbol), GroupIcon::Named))
}

pub(super) fn icon_value(icon: Option<&GroupIcon>) -> Option<String> {
    match icon? {
        GroupIcon::Named(named) => NAMED_SYMBOLS
            .iter()
            .find(|(known, _)| known == named)
            .map(|(_, name)| (*name).to_owned()),
        GroupIcon::Symbol(symbol) => Some(symbol.as_str().to_owned()),
    }
}

// Swift reads a missing number as 0.
pub(super) fn sort_key(raw: Option<i64>) -> i64 {
    raw.unwrap_or(0)
}

pub(super) fn favorite(raw: Option<i64>) -> bool {
    raw.is_some_and(|flag| flag != 0)
}

pub(super) fn favorite_value(favorite: bool) -> i64 {
    i64::from(favorite)
}

// The Foundation probe checks common English name ties; other locales can order ties differently.
pub(super) fn name_order(left: (&str, Uuid), right: (&str, Uuid)) -> Ordering {
    let (l, r) = (left.0, right.0);
    natural_text_order(&letters(l), &letters(r))
        .then_with(|| natural_text_order(&accented(l), &accented(r)))
        .then_with(|| cases(l).cmp(&cases(r)))
        .then_with(|| l.len().cmp(&r.len()))
        .then_with(|| l.cmp(r))
        .then(left.1.cmp(&right.1))
}

fn accented(text: &str) -> String {
    text.nfd().flat_map(char::to_lowercase).collect()
}

fn letters(text: &str) -> String {
    let mut folded = String::with_capacity(text.len());
    for c in text
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
    {
        match c {
            'ß' => folded.push_str("ss"),
            'æ' => folded.push_str("ae"),
            'œ' => folded.push_str("oe"),
            'þ' => folded.push_str("th"),
            'ø' => folded.push('o'),
            'đ' | 'ð' => folded.push('d'),
            'ł' => folded.push('l'),
            'ı' => folded.push('i'),
            _ => folded.push(c),
        }
    }
    folded
}

fn cases(text: &str) -> Vec<bool> {
    text.chars()
        .filter(|c| c.is_alphabetic())
        .map(char::is_uppercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Foundation's verdicts on macOS 27 in English, as the probe prints them.
    const FOUNDATION: [(&str, &str); 16] = [
        ("é", "z"),
        ("a", "A"),
        ("a", "B"),
        ("Prod 9", "Prod 10"),
        ("e", "é"),
        ("é", "f"),
        ("work", "Work"),
        ("a", "ä"),
        ("ss", "ß"),
        ("é", "Z"),
        ("_a", "a"),
        ("a b", "ab"),
        ("ü", "v"),
        ("Ø", "p"),
        ("1", "a"),
        ("a1", "a01"),
    ];

    #[test]
    fn names_order_as_finder_lists_them() {
        let id = Uuid::nil();
        for (first, second) in FOUNDATION {
            assert_eq!(
                name_order((first, id), (second, id)),
                Ordering::Less,
                "{first} before {second}"
            );
            assert_eq!(
                name_order((second, id), (first, id)),
                Ordering::Greater,
                "{second} after {first}"
            );
        }
    }

    #[test]
    fn the_same_name_falls_back_to_the_id() {
        let (low, high) = (Uuid::from_u128(1), Uuid::from_u128(2));

        assert_eq!(name_order(("Work", low), ("Work", high)), Ordering::Less);
    }
}
