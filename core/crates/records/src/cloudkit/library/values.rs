use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionIcon, LibraryIcon, SymbolName};
use uuid::Uuid;

// Keep unknown raw values until the user changes that field.

// As Swift's `UUID(uuidString:)` reads one: hyphenated, in either case.
pub(super) fn record_id(raw: &str) -> Option<Uuid> {
    (raw.len() == 36).then(|| Uuid::try_parse(raw).ok()).flatten()
}

pub(super) fn group_name(raw: Option<&str>) -> Option<ConnectionGroupName> {
    raw.and_then(ConnectionGroupName::cleaned_from)
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

pub(super) fn icon(raw: Option<&str>) -> Option<LibraryIcon> {
    let symbol = SymbolName::new(raw?)?;
    let named = NAMED_SYMBOLS
        .iter()
        .find(|(_, name)| *name == symbol.as_str())
        .map(|(icon, _)| *icon);
    Some(named.map_or(LibraryIcon::Symbol(symbol), LibraryIcon::Named))
}

pub(super) fn icon_value(icon: Option<&LibraryIcon>) -> Option<String> {
    match icon? {
        LibraryIcon::Named(named) => NAMED_SYMBOLS
            .iter()
            .find(|(known, _)| known == named)
            .map(|(_, name)| (*name).to_owned()),
        LibraryIcon::Symbol(symbol) => Some(symbol.as_str().to_owned()),
    }
}

pub(super) fn favorite(raw: Option<i64>) -> bool {
    raw.is_some_and(|flag| flag != 0)
}

pub(super) fn favorite_value(favorite: bool) -> i64 {
    i64::from(favorite)
}
